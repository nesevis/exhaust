// MARK: - Cooperative Drain Loop for Concurrent Contract Execution
//
// Executes a tagged command sequence through a cooperative scheduler that deterministically controls interleaving at every `await` boundary. The input is a flat [(ScheduleMarker, Command)] array that encodes both the lane partition AND the interleaving order:
//
//   - ScheduleMarker.prefix → runs sequentially before the concurrent phase (state setup)
//   - ScheduleMarker.laneA / .laneB → assigns to a lane; array position defines drain order
//
// The array order of non-prefix markers becomes the schedule: when the drain loop needs to pick which lane to advance, it consults the next marker in sequence. This encoding means reduction can simultaneously shrink commands (array deletion) and reduce concurrency (marker minimization toward 0/prefix) using the existing choice-graph reducer with no special logic.
//
// Execution model:
//   1. Partition commands into prefix / laneA / laneB
//   2. Drain the prefix phase sequentially on one executor
//   3. Spawn two Tasks (one per lane) with executorPreference pointing to LaneExecutors
//   4. Drain the run queue in schedule order until both lanes complete or a failure is detected
//
// Each Task.yield() or other suspension point in a command body produces a new continuation in the RunQueue, giving the scheduler a chance to switch lanes at that boundary.
import ExhaustCore

/// Assigns a command to a scheduling lane in a concurrent contract test.
///
/// During generation, the marker generator produces values in 0...2 uniformly. The reducer's value-minimization pass drives markers toward 0 (``prefix``), naturally discovering which commands must remain concurrent to reproduce the failure. Commands whose markers reach ``prefix`` move to the sequential phase, proving they are not part of the minimal concurrent counterexample.
///
/// ```
/// .prefix → sequential setup (run before any interleaving)
/// .laneA  → assigned to lane A (interleaved with lane B by the scheduler)
/// .laneB  → assigned to lane B (interleaved with lane A by the scheduler)
/// ```
public enum ScheduleMarker: UInt8, Sendable, Equatable, CustomStringConvertible {
    case prefix = 0
    case laneA = 1
    case laneB = 2

    public var description: String {
        switch self {
        case .prefix: "prefix"
        case .laneA: "a"
        case .laneB: "b"
        }
    }
}

/// Outcome of draining a single tagged command sequence through the cooperative scheduler.
struct ConcurrentExecutionResult {
    /// Whether all invariants held throughout the interleaved execution.
    var passed: Bool
    /// The execution trace, populated only when `recordTrace` is true.
    var trace: [TraceStep]
}

/// Drains a tagged command sequence through the cooperative scheduler with deterministic interleaving.
///
/// Execution proceeds in two phases. First, all ``ScheduleMarker/prefix`` commands run sequentially on a single executor — this builds up whatever shared state the concurrent phase needs. Then, ``ScheduleMarker/laneA`` and ``ScheduleMarker/laneB`` commands run concurrently via two Tasks whose continuations are interleaved by the drain loop.
///
/// The drain loop advances one continuation at a time (via `runSynchronously`), picking the lane indicated by the next schedule entry. When a command body hits an `await` (for example, `Task.yield()` inside a non-atomic read-modify-write), the task suspends and re-enqueues its continuation. The drain loop then picks the other lane's continuation, producing a deterministic interleaving at that suspension point.
///
/// - Parameter recordTrace: When false, trace recording is skipped for performance (used during generation and reduction where only pass/fail matters). When true, the full interleaving trace is captured for the final counterexample report.
func drainSchedule<Spec: AsyncContractSpec>(
    taggedCommands: [(ScheduleMarker, Spec.Command)],
    specInit: () -> Spec,
    recordTrace: Bool
) -> ConcurrentExecutionResult {
    let prefixCommands = taggedCommands.filter { $0.0 == .prefix }.map(\.1)
    let laneACommands = taggedCommands.filter { $0.0 == .laneA }.map(\.1)
    let laneBCommands = taggedCommands.filter { $0.0 == .laneB }.map(\.1)
    let schedule: [LaneID] = taggedCommands.compactMap { marker, _ in
        switch marker {
        case .laneA: .a
        case .laneB: .b
        case .prefix: nil
        }
    }

    let runQueue = RunQueue()
    let executorA = LaneExecutor(lane: .a, runQueue: runQueue)
    let executorB = LaneExecutor(lane: .b, runQueue: runQueue)
    let spec = SendableBox(specInit())
    let failed = SendableBox<String?>(nil)
    let trace = SendableBox<[String]>([])
    let commandIndexA = SendableBox(0)
    let commandIndexB = SendableBox(0)

    // Phase 1: Prefix — run sequentially, drain fully before concurrent phase.
    if prefixCommands.isEmpty == false {
        let prefixDone = SendableBox(false)
        Task(executorPreference: executorA) { @Sendable [spec, failed, prefixDone, trace] in
            for command in prefixCommands {
                guard failed.value == nil else { break }
                let description = "\(command)"
                if recordTrace { trace.value.append("STARTED:prefix:\(description)") }
                do {
                    try await spec.value.run(command)
                    try await spec.value.checkInvariants()
                    if recordTrace { trace.value.append("COMPLETED:prefix:\(description)") }
                } catch is ContractSkip {
                    if recordTrace { trace.value.append("COMPLETED:prefix:\(description)") }
                } catch let failure as ContractCheckFailure {
                    let message = failure.message ?? "check failed"
                    if recordTrace { trace.value.append("FAILED:prefix:\(description):\(message)") }
                    failed.value = message
                    break
                } catch {
                    if recordTrace { trace.value.append("FAILED:prefix:\(description):\(error)") }
                    failed.value = "\(error)"
                    break
                }
            }
            prefixDone.value = true
        }

        while prefixDone.value == false {
            guard let (_, job) = runQueue.dequeue(preferring: .a) else { continue }
            job.runSynchronously(on: executorA.asUnownedTaskExecutor())
        }
        if failed.value != nil {
            return ConcurrentExecutionResult(passed: false, trace: recordTrace ? parseTrace(trace.value) : [])
        }
    }

    // Phase 2: Concurrent — run lane A and lane B with interleaving.
    if laneACommands.isEmpty && laneBCommands.isEmpty {
        return ConcurrentExecutionResult(passed: true, trace: recordTrace ? parseTrace(trace.value) : [])
    }

    Task(executorPreference: executorA) { @Sendable [spec, failed, runQueue, trace, commandIndexA] in
        for command in laneACommands {
            guard failed.value == nil else { return }
            commandIndexA.value += 1
            let name = "\(command)".split(separator: "(").first.map(String.init) ?? "\(command)"
            let label = "\(commandIndexA.value)A \(name)"
            if recordTrace { trace.value.append("STARTED:a:\(label)") }
            do {
                try await spec.value.run(command)
                try await spec.value.checkInvariants()
                if recordTrace { trace.value.append("COMPLETED:a:\(label)") }
            } catch is ContractSkip {
                if recordTrace { trace.value.append("COMPLETED:a:\(label)") }
            } catch let failure as ContractCheckFailure {
                let message = failure.message ?? "check failed"
                if recordTrace { trace.value.append("FAILED:a:\(label):\(message)") }
                failed.value = message
                return
            } catch {
                if recordTrace { trace.value.append("FAILED:a:\(label):\(error)") }
                failed.value = "\(error)"
                return
            }
        }
        runQueue.markComplete(lane: .a)
    }

    Task(executorPreference: executorB) { @Sendable [spec, failed, runQueue, trace, commandIndexB] in
        for command in laneBCommands {
            guard failed.value == nil else { return }
            commandIndexB.value += 1
            let name = "\(command)".split(separator: "(").first.map(String.init) ?? "\(command)"
            let label = "\(commandIndexB.value)B \(name)"
            if recordTrace { trace.value.append("STARTED:b:\(label)") }
            do {
                try await spec.value.run(command)
                try await spec.value.checkInvariants()
                if recordTrace { trace.value.append("COMPLETED:b:\(label)") }
            } catch is ContractSkip {
                if recordTrace { trace.value.append("COMPLETED:b:\(label)") }
            } catch let failure as ContractCheckFailure {
                let message = failure.message ?? "check failed"
                if recordTrace { trace.value.append("FAILED:b:\(label):\(message)") }
                failed.value = message
                return
            } catch {
                if recordTrace { trace.value.append("FAILED:b:\(label):\(error)") }
                failed.value = "\(error)"
                return
            }
        }
        runQueue.markComplete(lane: .b)
    }

    if laneACommands.isEmpty { runQueue.markComplete(lane: .a) }
    if laneBCommands.isEmpty { runQueue.markComplete(lane: .b) }

    // Drain concurrent section with lane-switch tracking for suspended/resumed markers.
    var lastDrainedLane: LaneID?
    var laneHasOpenCommand: [LaneID: Bool] = [.a: false, .b: false]
    var scheduleIndex = 0
    var failureDetected = false

    while runQueue.isFinished == false {
        guard runQueue.hasPendingJobs else { break }
        let preferred: LaneID = if scheduleIndex < schedule.count {
            schedule[scheduleIndex]
        } else {
            scheduleIndex % 2 == 0 ? .a : .b
        }
        scheduleIndex += 1
        guard let (lane, job) = runQueue.dequeue(preferring: preferred) else { break }
        let executor = lane == .a ? executorA : executorB

        if recordTrace {
            let switchedLanes = lastDrainedLane != nil && lastDrainedLane != lane
            if switchedLanes, let prev = lastDrainedLane, laneHasOpenCommand[prev] == true {
                let laneLabel = prev == .a ? "a" : "b"
                trace.value.append("SUSPENDED:\(laneLabel)")
            }
            if switchedLanes && laneHasOpenCommand[lane] == true {
                let laneLabel = lane == .a ? "a" : "b"
                trace.value.append("RESUMED:\(laneLabel)")
            }
        }

        job.runSynchronously(on: executor.asUnownedTaskExecutor())
        laneHasOpenCommand[lane] = runQueue.hasPendingJob(for: lane)
        lastDrainedLane = lane

        if failed.value != nil {
            if failureDetected { break }
            failureDetected = true
        }
    }

    let finalTrace: [TraceStep] = recordTrace ? parseTrace(trace.value) : []
    return ConcurrentExecutionResult(passed: failed.value == nil, trace: finalTrace)
}
