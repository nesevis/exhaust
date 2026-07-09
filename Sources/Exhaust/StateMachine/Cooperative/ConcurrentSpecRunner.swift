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
struct ConcurrentExecutionResult<SystemUnderTest> {
    /// Whether all invariants held throughout the interleaved execution.
    var passed: Bool
    /// The execution trace, populated only when `recordTrace` is true.
    var trace: [TraceStep]
    /// Whether execution stalled because no continuations arrived within the idle timeout.
    var timedOut: Bool = false
    /// The SUT state after the concurrent execution, populated only when `recordTrace` is true.
    var systemUnderTest: SystemUnderTest?
    /// The spec's failure description after the concurrent execution, populated only when `recordTrace` is true and the execution failed.
    var failureDescription: String?
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
private func runCommandRecordingTrace<Spec: AsyncStateMachineSpec>(
    _ command: Spec.Command,
    on spec: UnsafeSendableBox<Spec>,
    lane: TraceEvent.Lane,
    label: String,
    trace: UnsafeSendableBox<[TraceEvent]>,
    recordTrace: Bool
) async -> CommandOutcome {
    // `label` is empty on the non-trace path; callers only build the (reflection-priced) command description when recordTrace is true.
    if recordTrace { trace.value.append(TraceEvent(kind: .started, lane: lane, label: label)) }
    do {
        try await spec.value.run(command)
    } catch is StateMachineSkip {
        if recordTrace { trace.value.append(TraceEvent(kind: .skipped, lane: lane, label: label)) }
        return .skipped
    } catch let failure as StateMachineCheckFailure {
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
    } catch is StateMachineSkip {
        if recordTrace { trace.value.append(TraceEvent(kind: .completed, lane: lane, label: label)) }
    } catch let failure as StateMachineCheckFailure {
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
/// Execution proceeds in two phases. First, all prefix commands run sequentially on a single executor to build up whatever shared state the concurrent phase needs. Then, lane-assigned commands run concurrently via N Tasks whose continuations are interleaved by the drain loop.
///
/// The drain loop advances one continuation at a time (via `runSynchronously`), picking the lane indicated by the next schedule entry. When a command body hits an `await` (for example, `Task.yield()` inside a non-atomic read-modify-write), the task suspends and re-enqueues its continuation. The drain loop then picks another lane's continuation, producing a deterministic interleaving at that suspension point.
///
/// - Parameter concurrencyLevel: The number of concurrent lanes (1...8). When 1, the generator tags every command as prefix, so the entire sequence runs in the sequential prefix phase and the lane drain never executes.
/// - Parameter recordTrace: When false, trace recording is skipped for performance (used during generation and reduction where only pass/fail matters). When true, the full interleaving trace is captured for the final counterexample report.
/// - Parameter idleTimeoutMilliseconds: Maximum wall-clock time (in milliseconds) the drain loop waits with no pending jobs before declaring a timeout. Prevents infinite hangs when a continuation escapes to a foreign executor. Pass `Int.max` to disable.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
func drainSchedule<Spec: AsyncStateMachineSpec>(
    taggedCommands: [(ScheduleMarker, Spec.Command)],
    specInit: () -> Spec,
    concurrencyLevel: Int,
    recordTrace: Bool,
    idleTimeoutMilliseconds: Int = 1000
) -> ConcurrentExecutionResult<Spec.SystemUnderTest> {
    // One pass replaces the per-lane filter passes: prefix commands, per-lane buckets, and the schedule all fall out of a single scan. The lane-bounds guard mirrors the old per-lane filter — markers above the concurrency level contribute a schedule entry but no lane command, exactly as before. The results are rebound as lets so the `@Sendable` lane tasks can capture them.
    var prefixBuffer: [Spec.Command] = []
    var laneBuffer: [[Spec.Command]] = Array(repeating: [], count: concurrencyLevel)
    var scheduleBuffer: [LaneID] = []
    for (marker, command) in taggedCommands {
        guard let laneIndex = marker.laneIndex else {
            prefixBuffer.append(command)
            continue
        }
        scheduleBuffer.append(LaneID(index: laneIndex))
        if Int(laneIndex) < concurrencyLevel {
            laneBuffer[Int(laneIndex)].append(command)
        }
    }
    let prefixCommands = prefixBuffer
    let laneCommands = laneBuffer
    let schedule = scheduleBuffer

    let runQueue = RunQueue(laneCount: concurrencyLevel)
    let executors: [LaneExecutor] = (0 ..< concurrencyLevel).map { index in
        LaneExecutor(lane: LaneID(index: UInt8(index)), runQueue: runQueue)
    }
    // Single-threaded: Task closures are nonisolated with executorPreference, so all box accesses run via runSynchronously on the drain thread. Foreign-executor segments (MainActor, custom-executor actors) execute only user code that never touches these boxes. New box accesses must stay in nonisolated closure code.
    let spec = UnsafeSendableBox(specInit())
    let failed = UnsafeSendableBox<String?>(nil)
    let trace = UnsafeSendableBox<[TraceEvent]>([])
    let commandIndices: [UnsafeSendableBox<Int>] = (0 ..< concurrencyLevel).map { _ in UnsafeSendableBox(0) }

    if prefixCommands.isEmpty == false {
        let prefixDone = UnsafeSendableBox(false)
        Task(executorPreference: executors[0]) { @Sendable [spec, failed, prefixDone, trace] in
            for command in prefixCommands {
                guard failed.value == nil else { break }
                let label = recordTrace ? "\(command)" : ""
                let outcome = await runCommandRecordingTrace(
                    command, on: spec, lane: .prefix, label: label,
                    trace: trace, recordTrace: recordTrace
                )
                if case let .failed(message) = outcome {
                    failed.value = message
                    break
                }
            }
            prefixDone.value = true
        }

        if ScheduleDrain.drainUntilDone(
            prefixDone,
            runQueue: runQueue,
            executor: executors[0],
            idleTimeoutMilliseconds: idleTimeoutMilliseconds
        ) == .timedOut {
            return ConcurrentExecutionResult(
                passed: false,
                trace: recordTrace
                    ? __ExhaustRuntime.buildTrace(trace.value)
                    : [],
                timedOut: true
            )
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
            let traceLane = TraceEvent.Lane.lane(lane)
            for command in commands {
                guard failed.value == nil else { return }
                commandIndex.value += 1
                let label: String
                if recordTrace {
                    let name = "\(command)".split(separator: "(").first.map(String.init) ?? "\(command)"
                    label = "\(commandIndex.value)\(traceLane) \(name)"
                } else {
                    label = ""
                }
                let outcome = await runCommandRecordingTrace(
                    command, on: spec, lane: traceLane, label: label,
                    trace: trace, recordTrace: recordTrace
                )
                if case let .failed(message) = outcome {
                    failed.value = message
                    return
                }
            }
        }
    }

    // Drain the concurrent section via the core engine. Lane-switch tracking for suspended/resumed markers only exists when a trace is recorded; the nil handler on the probe path also skips the engine's per-continuation open-command bookkeeping.
    let onTraceSignal: ((ScheduleDrain.TraceSignal) -> Void)? = recordTrace
        ? { signal in
            switch signal {
                case let .suspended(lane):
                    trace.value.append(TraceEvent(kind: .suspended, lane: .lane(lane), label: ""))
                case let .resumed(lane):
                    trace.value.append(TraceEvent(kind: .resumed, lane: .lane(lane), label: ""))
            }
        }
        : nil

    if ScheduleDrain.drainConcurrentSection(
        runQueue: runQueue,
        executors: executors,
        schedule: schedule,
        concurrencyLevel: concurrencyLevel,
        idleTimeoutMilliseconds: idleTimeoutMilliseconds,
        failureFlag: failed,
        onTraceSignal: onTraceSignal
    ) == .timedOut {
        let finalTrace: [TraceStep] = recordTrace
            ? __ExhaustRuntime.buildTrace(trace.value)
            : []
        return ConcurrentExecutionResult(passed: false, trace: finalTrace, timedOut: true)
    }

    let finalTrace: [TraceStep] = recordTrace
        ? __ExhaustRuntime.buildTrace(trace.value)
        : []
    let concurrentFailed = failed.value != nil
    return ConcurrentExecutionResult(
        passed: concurrentFailed == false,
        trace: finalTrace,
        systemUnderTest: recordTrace ? spec.value.systemUnderTest : nil,
        failureDescription: concurrentFailed && recordTrace ? spec.value.failureDescription() : nil
    )
}
