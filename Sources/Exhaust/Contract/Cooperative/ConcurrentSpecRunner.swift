//
// Executes a tagged command sequence through a cooperative scheduler that deterministically controls interleaving at every `await` boundary. The input is a flat [(ScheduleMarker, Command)] array that encodes both the lane partition AND the interleaving order:
//
//   - ScheduleMarker(rawValue: 0) → prefix: runs sequentially before the concurrent phase (state setup)
//   - ScheduleMarker(rawValue: 1...N) → assigns to lane a...n; array position defines drain order
//
// The array order of non-prefix markers becomes the schedule: when the drain loop needs to pick which lane to advance, it consults the next marker in sequence. This encoding means reduction can simultaneously reduce commands (array deletion) and reduce concurrency (marker minimization toward 0/prefix) using the existing choice-graph reducer with no special logic.
//
// Execution model:
//   1. Partition commands into prefix + one array per lane
//   2. Drain the prefix phase sequentially on one executor
//   3. Spawn N Tasks (one per lane) with executorPreference pointing to their LaneExecutor
//   4. Drain the run queue in schedule order until all lanes complete or a failure is detected
//
// Each Task.yield() or other suspension point in a command body produces a new continuation in the RunQueue, giving the scheduler a chance to switch lanes at that boundary.
//
// Limitation: the schedule array has one entry per non-prefix command, but the drain loop consumes one entry per dequeued job, including continuations from internal suspension points. Commands that suspend multiple times consume schedule entries meant for later commands, causing the schedule to exhaust early. Once exhausted, lane assignment falls back to deterministic round-robin (`scheduleIndex % concurrencyLevel`). Command-level lane assignment and ordering remain fully reducible; continuation-level interleavings are not encoded in the choice sequence because the number of suspension points per command is a runtime property that cannot be known before execution.
import ExhaustCore

/// Outcome of draining a single tagged command sequence through the cooperative scheduler.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
struct ConcurrentExecutionResult {
    /// Whether all invariants held throughout the interleaved execution.
    var passed: Bool
    /// The execution trace, populated only when `recordTrace` is true.
    var trace: [TraceStep]
    /// Whether execution stalled because no continuations arrived within the idle timeout.
    var timedOut: Bool = false
}

/// Outcome of running a single command and checking its invariants inside the drain loop.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private enum CommandOutcome {
    case ok
    case skipped
    case failed(String)
}

/// Runs a single command, checks invariants, and records trace events. Returns the outcome so the caller can handle exit flow (`break` in the prefix loop, `return` in a lane Task).
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func runCommandRecordingTrace<Spec: AsyncContractSpec>(
    _ command: Spec.Command,
    on spec: UnsafeSendableBox<Spec>,
    lane: String,
    label: String,
    trace: UnsafeSendableBox<[TraceEvent]>,
    recordTrace: Bool
) async -> CommandOutcome {
    if recordTrace { trace.value.append(TraceEvent(kind: .started, lane: lane, label: label)) }
    do {
        try await spec.value.run(command)
    } catch is ContractSkip {
        if recordTrace { trace.value.append(TraceEvent(kind: .skipped, lane: lane, label: label)) }
        return .skipped
    } catch let failure as ContractCheckFailure {
        let message = failure.message ?? "check failed"
        if recordTrace {
            trace.value.append(TraceEvent(kind: .failed(message: message, source: .check), lane: lane, label: label))
        }
        return .failed(message)
    } catch {
        if recordTrace {
            trace.value.append(TraceEvent(kind: .failed(message: "\(error)", source: .error), lane: lane, label: label))
        }
        return .failed("\(error)")
    }
    do {
        try await spec.value.checkInvariants()
        if recordTrace { trace.value.append(TraceEvent(kind: .completed, lane: lane, label: label)) }
    } catch is ContractSkip {
        if recordTrace { trace.value.append(TraceEvent(kind: .completed, lane: lane, label: label)) }
    } catch let failure as ContractCheckFailure {
        let message = failure.message ?? "check failed"
        if recordTrace {
            trace.value.append(TraceEvent(kind: .failed(message: message, source: .invariant), lane: lane, label: label))
        }
        return .failed(message)
    } catch {
        if recordTrace {
            trace.value.append(TraceEvent(kind: .failed(message: "\(error)", source: .invariant), lane: lane, label: label))
        }
        return .failed("\(error)")
    }
    return .ok
}

/// Drains a tagged command sequence through the cooperative scheduler with deterministic interleaving.
///
/// Execution proceeds in two phases. First, all prefix commands run sequentially on a single executor — this builds up whatever shared state the concurrent phase needs. Then, lane-assigned commands run concurrently via N Tasks whose continuations are interleaved by the drain loop.
///
/// The drain loop advances one continuation at a time (via `runSynchronously`), picking the lane indicated by the next schedule entry. When a command body hits an `await` (for example, `Task.yield()` inside a non-atomic read-modify-write), the task suspends and re-enqueues its continuation. The drain loop then picks another lane's continuation, producing a deterministic interleaving at that suspension point.
///
/// - Parameter concurrencyLevel: The number of concurrent lanes (1...8). When 1, all non-prefix commands run on a single lane with no interleaving (fast path).
/// - Parameter recordTrace: When false, trace recording is skipped for performance (used during generation and reduction where only pass/fail matters). When true, the full interleaving trace is captured for the final counterexample report.
/// - Parameter idleTimeoutMilliseconds: Maximum wall-clock time (in milliseconds) the drain loop waits with no pending jobs before declaring a timeout. Prevents infinite hangs when a continuation escapes to a foreign executor. Pass `Int.max` to disable.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
func drainSchedule<Spec: AsyncContractSpec>(
    taggedCommands: [(ScheduleMarker, Spec.Command)],
    specInit: () -> Spec,
    concurrencyLevel: Int,
    recordTrace: Bool,
    idleTimeoutMilliseconds: Int = 1000
) -> ConcurrentExecutionResult {
    let prefixCommands = taggedCommands.filter(\.0.isPrefix).map(\.1)
    let laneCommands: [[Spec.Command]] = (0 ..< concurrencyLevel).map { laneIndex in
        let marker = ScheduleMarker(rawValue: UInt8(laneIndex + 1))
        return taggedCommands.filter { $0.0 == marker }.map(\.1)
    }
    let schedule: [LaneID] = taggedCommands.compactMap { marker, _ in
        guard let laneIndex = marker.laneIndex else { return nil }
        return LaneID(index: laneIndex)
    }

    let runQueue = RunQueue(laneCount: concurrencyLevel)
    let executors: [LaneExecutor] = (0 ..< concurrencyLevel).map { index in
        LaneExecutor(lane: LaneID(index: UInt8(index)), runQueue: runQueue)
    }
    // Shared mutable state accessed from Task closures and the drain loop. Thread safety relies on the cooperative single-threaded execution model: all Task closures execute via runSynchronously on the drain loop thread, and LaneExecutor.enqueue (the only re-entry point) is called synchronously within runSynchronously's suspension machinery. No concurrent access is possible as long as all continuations flow through LaneExecutor. If a continuation arrives from a foreign executor (custom-executor actor, Task.sleep), RunQueue itself would race first — the UnsafeSendableBox invariant is the same as RunQueue's.
    let spec = UnsafeSendableBox(specInit())
    let failed = UnsafeSendableBox<String?>(nil)
    let trace = UnsafeSendableBox<[TraceEvent]>([])
    let commandIndices: [UnsafeSendableBox<Int>] = (0 ..< concurrencyLevel).map { _ in UnsafeSendableBox(0) }

    if prefixCommands.isEmpty == false {
        let prefixDone = UnsafeSendableBox(false)
        Task(executorPreference: executors[0]) { @Sendable [spec, failed, prefixDone, trace] in
            for command in prefixCommands {
                guard failed.value == nil else { break }
                let label = "\(command)"
                let outcome = await runCommandRecordingTrace(
                    command, on: spec, lane: "prefix", label: label,
                    trace: trace, recordTrace: recordTrace
                )
                if case let .failed(message) = outcome {
                    failed.value = message
                    break
                }
            }
            prefixDone.value = true
        }

        var idleStopwatch = Stopwatch()
        while prefixDone.value == false {
            guard let (_, job) = runQueue.dequeue(preferring: LaneID(index: 0)) else {
                if runQueue.waitForJob(
                    idleTimeoutMilliseconds: idleTimeoutMilliseconds,
                    elapsedMilliseconds: idleStopwatch.elapsedMilliseconds
                ) == false {
                    return ConcurrentExecutionResult(
                        passed: false,
                        trace: recordTrace
                            ? __ExhaustRuntime.buildTrace(trace.value)
                            : [],
                        timedOut: true
                    )
                }
                continue
            }
            job.runSynchronously(on: executors[0].asUnownedTaskExecutor())
            idleStopwatch = Stopwatch()
        }
        if failed.value != nil {
            return ConcurrentExecutionResult(
                passed: false,
                trace: recordTrace
                    ? __ExhaustRuntime.buildTrace(trace.value)
                    : []
            )
        }
    }

    let hasAnyLaneCommands = laneCommands
        .contains { $0.isEmpty == false }
    if hasAnyLaneCommands == false {
        return ConcurrentExecutionResult(
            passed: true,
            trace: recordTrace
                ? __ExhaustRuntime.buildTrace(trace.value)
                : []
        )
    }

    for (laneIndex, commands) in laneCommands.enumerated() {
        let lane = LaneID(index: UInt8(laneIndex))
        let executor = executors[laneIndex]
        let commandIndex = commandIndices[laneIndex]

        if commands.isEmpty {
            runQueue.markComplete(lane: lane)
            continue
        }

        Task(executorPreference: executor) { @Sendable [spec, failed, runQueue, trace, commandIndex] in
            defer { runQueue.markComplete(lane: lane) }
            let laneLabel = lane.label
            for command in commands {
                guard failed.value == nil else { return }
                commandIndex.value += 1
                let name = "\(command)".split(separator: "(").first.map(String.init) ?? "\(command)"
                let label = "\(commandIndex.value)\(laneLabel.uppercased()) \(name)"
                let outcome = await runCommandRecordingTrace(
                    command, on: spec, lane: laneLabel, label: label,
                    trace: trace, recordTrace: recordTrace
                )
                if case let .failed(message) = outcome {
                    failed.value = message
                    return
                }
            }
        }
    }

    // Drain concurrent section with lane-switch tracking for suspended/resumed markers.
    var lastDrainedLane: LaneID?
    var laneHasOpenCommand: [LaneID: Bool] = Dictionary(
        uniqueKeysWithValues: (0 ..< concurrencyLevel).map { (LaneID(index: UInt8($0)), false) }
    )
    var scheduleIndex = 0

    var idleStopwatch = Stopwatch()

    while runQueue.isFinished == false {
        if runQueue.hasPendingJobs == false {
            if runQueue.waitForJob(
                idleTimeoutMilliseconds: idleTimeoutMilliseconds,
                elapsedMilliseconds: idleStopwatch.elapsedMilliseconds
            ) == false {
                let finalTrace: [TraceStep] = recordTrace
                    ? __ExhaustRuntime.buildTrace(trace.value)
                    : []
                return ConcurrentExecutionResult(passed: false, trace: finalTrace, timedOut: true)
            }
            continue
        }
        let preferred = scheduleIndex < schedule.count
            ? schedule[scheduleIndex]
            : LaneID(index: UInt8(scheduleIndex % concurrencyLevel))
        scheduleIndex += 1
        guard let (lane, job) = runQueue.dequeue(preferring: preferred) else {
            assertionFailure("dequeue returned nil despite hasPendingJobs being true")
            break
        }
        let executor = executors[Int(lane.index)]

        if recordTrace {
            let switchedLanes = lastDrainedLane != nil && lastDrainedLane != lane
            if switchedLanes, let prev = lastDrainedLane, laneHasOpenCommand[prev] == true {
                trace.value.append(TraceEvent(kind: .suspended, lane: prev.label, label: ""))
            }
            if switchedLanes, laneHasOpenCommand[lane] == true {
                trace.value.append(TraceEvent(kind: .resumed, lane: lane.label, label: ""))
            }
        }

        job.runSynchronously(on: executor.asUnownedTaskExecutor())
        laneHasOpenCommand[lane] = runQueue.hasPendingJob(for: lane)
        lastDrainedLane = lane
        idleStopwatch = Stopwatch()

        if failed.value != nil {
            break
        }
    }

    let finalTrace: [TraceStep] = recordTrace
        ? __ExhaustRuntime.buildTrace(trace.value)
        : []
    return ConcurrentExecutionResult(passed: failed.value == nil, trace: finalTrace)
}
