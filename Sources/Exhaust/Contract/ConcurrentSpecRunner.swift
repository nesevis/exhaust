// Concurrent contract runner with deterministic interleaving via custom executors.
//
// Generates test inputs (two command sequences + a schedule), executes them through
// the ControlledExecutor drain loop, and reduces failures via the ChoiceGraph reducer.
// The entire execution is deterministic: same seed → same interleaving → same result.
import ExhaustCore
import IssueReporting

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

/// Input for a single concurrent test iteration: two command sequences and an interleaving schedule.
struct ConcurrentTestInput<Command: Sendable>: Sendable {
    var commandsA: [Command]
    var commandsB: [Command]
    var schedule: [UInt8]
}

/// Evaluates a concurrent test input against a spec using deterministic interleaving.
///
/// The drain loop runs on the calling thread, executing jobs from both tasks one at a time
/// according to the schedule. Each `await` in a command body creates a new job submission,
/// and the schedule determines which task's job runs next — giving sub-command interleaving.
func evaluateConcurrentProperty<Spec: AsyncContractSpec>(
    input: ConcurrentTestInput<Spec.Command>,
    specInit: @Sendable () -> Spec
) -> Bool {
    let shared = SharedDrainState()
    let executorA = LaneExecutor(lane: .a, shared: shared)
    let executorB = LaneExecutor(lane: .b, shared: shared)
    let spec = SendableBox(specInit())
    let failed = SendableBox(false)

    Task(executorPreference: executorA) { @Sendable [spec, failed, shared] in
        for command in input.commandsA {
            guard failed.value == false else { return }
            do {
                try await spec.value.run(command)
                try await spec.value.checkInvariants()
            } catch is ContractSkip {
                continue
            } catch {
                failed.value = true
                return
            }
        }
        shared.markComplete(lane: .a)
    }

    Task(executorPreference: executorB) { @Sendable [spec, failed, shared] in
        for command in input.commandsB {
            guard failed.value == false else { return }
            do {
                try await spec.value.run(command)
                try await spec.value.checkInvariants()
            } catch is ContractSkip {
                continue
            } catch {
                failed.value = true
                return
            }
        }
        shared.markComplete(lane: .b)
    }

    // Drain loop: deterministic interleaving driven by the schedule.
    var scheduleIndex = 0
    while shared.isFinished == false {
        guard shared.hasPendingJobs else { break }

        let preferred: LaneID
        if scheduleIndex < input.schedule.count {
            preferred = input.schedule[scheduleIndex] == 0 ? .a : .b
            scheduleIndex += 1
        } else {
            preferred = scheduleIndex % 2 == 0 ? .a : .b
            scheduleIndex += 1
        }

        guard let (lane, job) = shared.takeJob(preferring: preferred) else { break }
        let executor = lane == .a ? executorA : executorB
        job.runSynchronously(on: executor.asUnownedTaskExecutor())

        if failed.value { break }
    }

    return failed.value == false
}
