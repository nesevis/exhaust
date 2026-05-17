// Concurrent contract execution via deterministic interleaving.
//
// A flat [(thread, command)] array defines both the partition and the schedule. Thread markers
// 1 (A) and 2 (B) assign commands to lanes. The array order defines the interleaving: when
// draining, each non-prefix marker in sequence tells the executor which lane to advance next.
// Reduction minimizes markers toward 0 (prefix), naturally discovering which commands must be
// concurrent to trigger the failure.
import ExhaustCore

/// Thread assignment for a command in a concurrent contract test.
///
/// During generation, commands are assigned to ``threadA`` or ``threadB``. The ``prefix`` value
/// exists only as a reduction target — the reducer minimizes thread markers toward ``prefix`` to
/// discover the minimal concurrency needed to trigger a failure.
public enum ContractThread: UInt8, Sendable, Equatable, CustomStringConvertible {
    case prefix = 0
    case threadA = 1
    case threadB = 2

    public var description: String {
        switch self {
        case .prefix: "prefix"
        case .threadA: "a"
        case .threadB: "b"
        }
    }
}

/// Result of executing a concurrent test input.
struct ConcurrentExecutionResult {
    var passed: Bool
    var trace: [TraceStep]
}

/// Executes a tagged command sequence with deterministic interleaving and returns the result.
///
/// When `recordTrace` is false, trace recording is skipped for performance (used during
/// generation and reduction). When true, the full interleaving trace is captured (used for
/// the final counterexample).
func executeConcurrent<Spec: AsyncContractSpec>(
    taggedCommands: [(ContractThread, Spec.Command)],
    specInit: () -> Spec,
    recordTrace: Bool
) -> ConcurrentExecutionResult {
    let prefixCommands = taggedCommands.filter { $0.0 == .prefix }.map(\.1)
    let threadACommands = taggedCommands.filter { $0.0 == .threadA }.map(\.1)
    let threadBCommands = taggedCommands.filter { $0.0 == .threadB }.map(\.1)
    let schedule: [LaneID] = taggedCommands.compactMap { thread, _ in
        switch thread {
        case .threadA: .a
        case .threadB: .b
        case .prefix: nil
        }
    }

    let shared = SharedDrainState()
    let executorA = LaneExecutor(lane: .a, shared: shared)
    let executorB = LaneExecutor(lane: .b, shared: shared)
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
            guard let (_, job) = shared.takeJob(preferring: .a) else { continue }
            job.runSynchronously(on: executorA.asUnownedTaskExecutor())
        }
        if failed.value != nil {
            return ConcurrentExecutionResult(passed: false, trace: recordTrace ? parseTrace(trace.value) : [])
        }
    }

    // Phase 2: Concurrent — run thread A and thread B with interleaving.
    if threadACommands.isEmpty && threadBCommands.isEmpty {
        return ConcurrentExecutionResult(passed: true, trace: recordTrace ? parseTrace(trace.value) : [])
    }

    Task(executorPreference: executorA) { @Sendable [spec, failed, shared, trace, commandIndexA] in
        for command in threadACommands {
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
        shared.markComplete(lane: .a)
    }

    Task(executorPreference: executorB) { @Sendable [spec, failed, shared, trace, commandIndexB] in
        for command in threadBCommands {
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
        shared.markComplete(lane: .b)
    }

    if threadACommands.isEmpty { shared.markComplete(lane: .a) }
    if threadBCommands.isEmpty { shared.markComplete(lane: .b) }

    // Drain concurrent section with lane-switch tracking for suspended/resumed markers.
    var lastDrainedLane: LaneID?
    var laneHasOpenCommand: [LaneID: Bool] = [.a: false, .b: false]
    var scheduleIndex = 0
    var failureDetected = false

    while shared.isFinished == false {
        guard shared.hasPendingJobs else { break }
        let preferred: LaneID = if scheduleIndex < schedule.count {
            schedule[scheduleIndex]
        } else {
            scheduleIndex % 2 == 0 ? .a : .b
        }
        scheduleIndex += 1
        guard let (lane, job) = shared.takeJob(preferring: preferred) else { break }
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
        laneHasOpenCommand[lane] = shared.hasPendingJob(for: lane)
        lastDrainedLane = lane

        if failed.value != nil {
            if failureDetected { break }
            failureDetected = true
        }
    }

    let finalTrace: [TraceStep] = recordTrace ? parseTrace(trace.value) : []
    return ConcurrentExecutionResult(passed: failed.value == nil, trace: finalTrace)
}
