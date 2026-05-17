// MARK: - Cooperative Task Executor for Deterministic Interleaving
//
// This file implements a cooperative scheduling pattern identical to Swift's own CooperativeExecutor (stdlib/public/Concurrency/CooperativeExecutor.swift). Two LaneExecutor instances share a single RunQueue. The drain loop — run synchronously by the calling thread — picks jobs from the queue based on a generated schedule and executes each via runSynchronously(on:).
//
// Key invariant: one runSynchronously call executes exactly one continuation — the synchronous code between two suspension points. When a task hits an `await`, the runtime re-enqueues the next continuation through LaneExecutor.enqueue(_:), which deposits it back into the RunQueue. The drain loop then picks the next job (potentially from the other lane), producing deterministic sub-command interleaving at every await boundary.
//
// Thread safety: all access to RunQueue happens on the drain loop thread. The LaneExecutor's enqueue(_:) is called by the Swift runtime as part of the suspension machinery within runSynchronously, before it returns — so it also runs on the drain loop thread. This holds as long as no continuation arrives from a foreign executor (for example, a custom-executor actor or Task.sleep). Default actors respect the task's executor preference (SE-0417) and their jobs flow through LaneExecutor normally.
import Foundation

/// Identifies a logical execution lane in a concurrent contract test.
///
/// Lane A and lane B run commands concurrently (interleaved by the cooperative scheduler). The raw values are stable and used as dictionary keys in trace recording.
enum LaneID: UInt8, Sendable {
    case a = 0
    case b = 1
}

/// Tags enqueued jobs with a lane identifier and deposits them into the shared ``RunQueue``.
///
/// Each concurrent contract test creates two LaneExecutor instances (one per lane) sharing the same RunQueue. When a task with `executorPreference` set to this executor suspends and later resumes, the Swift runtime calls ``enqueue(_:)`` to schedule the next continuation. The lane tag lets the drain loop identify which lane produced the job without inspecting the job's content.
///
/// Marked `@unchecked Sendable` because all access occurs on the single drain loop thread. The `enqueue(_:)` call happens within `runSynchronously`'s suspension machinery, which executes on the same thread as the drain loop.
final class LaneExecutor: TaskExecutor, @unchecked Sendable {
    let lane: LaneID
    let runQueue: RunQueue

    init(lane: LaneID, runQueue: RunQueue) {
        self.lane = lane
        self.runQueue = runQueue
    }

    func enqueue(_ job: consuming ExecutorJob) {
        runQueue.enqueue(lane: lane, job: UnownedJob(job))
    }

    func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}

/// Collects tagged jobs from both lane executors and dispatches them under schedule control.
///
/// The drain loop calls ``dequeue(preferring:)`` in a tight loop, passing the next lane from the generated schedule. If a job for the preferred lane exists, it is returned; otherwise the queue falls back to any available job. This "prefer but don't block" policy means the generated schedule controls interleaving when both lanes have pending work, and automatically drains whichever lane is still active when the other has no pending continuations.
///
/// Marked `@unchecked Sendable` because all access occurs on the single drain loop thread. See the file header for the thread safety argument.
final class RunQueue: @unchecked Sendable {
    private var jobs: [(lane: LaneID, job: UnownedJob)] = []
    private var completedLanes: Set<LaneID> = []

    /// Appends a tagged job to the queue.
    func enqueue(lane: LaneID, job: UnownedJob) {
        jobs.append((lane: lane, job: job))
    }

    /// Records that a lane's task has finished executing all its commands.
    func markComplete(lane: LaneID) {
        completedLanes.insert(lane)
    }

    /// Returns true when both lanes have completed and no jobs remain.
    var isFinished: Bool {
        completedLanes.count == 2 && jobs.isEmpty
    }

    /// Returns true when at least one job is available for draining.
    var hasPendingJobs: Bool {
        jobs.isEmpty == false
    }

    /// Removes and returns the next job, preferring the specified lane.
    ///
    /// Falls back to any available job if the preferred lane has none pending. Returns nil only when the queue is empty.
    func dequeue(preferring preferred: LaneID) -> (lane: LaneID, job: UnownedJob)? {
        if let index = jobs.firstIndex(where: { $0.lane == preferred }) {
            return jobs.remove(at: index)
        }
        if jobs.isEmpty == false {
            return jobs.removeFirst()
        }
        return nil
    }

    /// Returns true when the specified lane has at least one pending job.
    func hasPendingJob(for lane: LaneID) -> Bool {
        jobs.contains { $0.lane == lane }
    }
}
