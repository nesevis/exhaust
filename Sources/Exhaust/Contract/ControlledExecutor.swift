// Custom serial executor for deterministic concurrent contract testing.
//
// Two LaneExecutor instances share a single drain queue. Each tags jobs with its lane ID
// on enqueue. The drain loop (run synchronously by the property closure) picks jobs based
// on a generated schedule and executes them via runSynchronously — giving deterministic,
// reproducible sub-command interleaving at every await boundary.
import Foundation

/// Identifies a logical execution lane in a concurrent contract test.
enum LaneID: UInt8, Sendable {
    case a = 0
    case b = 1
}

/// A task executor for one lane that tags all submitted jobs and deposits them into the shared drain state.
final class LaneExecutor: TaskExecutor, @unchecked Sendable {
    let lane: LaneID
    let shared: SharedDrainState

    init(lane: LaneID, shared: SharedDrainState) {
        self.lane = lane
        self.shared = shared
    }

    func enqueue(_ job: consuming ExecutorJob) {
        shared.submit(lane: lane, job: UnownedJob(job))
    }

    func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}

/// Collects jobs from both lane executors and provides schedule-driven draining.
final class SharedDrainState: @unchecked Sendable {
    private var pending: [(lane: LaneID, job: UnownedJob)] = []
    private var completedLanes: Set<LaneID> = []

    func submit(lane: LaneID, job: UnownedJob) {
        pending.append((lane: lane, job: job))
    }

    func markComplete(lane: LaneID) {
        completedLanes.insert(lane)
    }

    var isFinished: Bool {
        completedLanes.count == 2 && pending.isEmpty
    }

    var hasPendingJobs: Bool {
        pending.isEmpty == false
    }

    /// Takes the next job, preferring the specified lane. Falls back to any available job.
    func takeJob(preferring preferred: LaneID) -> (lane: LaneID, job: UnownedJob)? {
        if let index = pending.firstIndex(where: { $0.lane == preferred }) {
            return pending.remove(at: index)
        }
        if pending.isEmpty == false {
            return pending.removeFirst()
        }
        return nil
    }

    /// Whether the given lane has any pending jobs.
    func hasPendingJob(for lane: LaneID) -> Bool {
        pending.contains { $0.lane == lane }
    }
}
