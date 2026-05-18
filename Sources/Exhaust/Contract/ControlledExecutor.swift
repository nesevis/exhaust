// MARK: - Cooperative Task Executor for Deterministic Interleaving
//
// This file implements a cooperative scheduling pattern identical to Swift's own CooperativeExecutor (stdlib/public/Concurrency/CooperativeExecutor.swift). N LaneExecutor instances share a single RunQueue. The drain loop — run synchronously by the calling thread — picks jobs from the queue based on a generated schedule and executes each via runSynchronously(on:).
//
// Key invariant: one runSynchronously call executes exactly one continuation — the synchronous code between two suspension points. When a task hits an `await`, the runtime re-enqueues the next continuation through LaneExecutor.enqueue(_:), which deposits it back into the RunQueue. The drain loop then picks the next job (potentially from another lane), producing deterministic sub-command interleaving at every await boundary.
//
// Thread safety: RunQueue is protected by Mutex. In the common case (all continuations flow through LaneExecutor on the drain loop thread), the lock is uncontended. The lock exists because SUTs commonly wrap GCD-based code in async/await facades (for example, a database that uses DispatchQueue internally but exposes an async API via withCheckedContinuation). When the SUT's GCD work completes, the continuation is re-enqueued to LaneExecutor from the GCD thread, not the drain loop thread. Without the lock, this concurrent enqueue races with the drain loop's dequeue on the per-lane arrays. Custom-executor actors and Task.sleep produce the same cross-thread re-enqueue pattern.
import Foundation
import Synchronization

/// Identifies a logical execution lane in a concurrent contract test.
///
/// Lane indices are zero-based: lane 0 is "a", lane 1 is "b", and so on up to the concurrency level minus one. The label maps index to a lowercase ASCII letter for trace output.
struct LaneID: Hashable, Sendable {
    let index: UInt8

    var label: String {
        String(UnicodeScalar(UInt8(ascii: "a") + index))
    }
}

/// Tags enqueued jobs with a lane identifier and deposits them into the shared ``RunQueue``.
///
/// Each concurrent contract test creates one LaneExecutor per lane, all sharing the same RunQueue. When a task with `executorPreference` set to this executor suspends and later resumes, the Swift runtime calls ``enqueue(_:)`` to schedule the next continuation. The lane tag lets the drain loop identify which lane produced the job without inspecting the job's content.
///
/// Marked `@unchecked Sendable` because ``enqueue(_:)`` may be called from any thread (when a continuation arrives from a foreign executor). Thread safety is provided by ``RunQueue``'s lock.
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

/// Collects tagged jobs from all lane executors and dispatches them under schedule control.
///
/// The drain loop calls ``dequeue(preferring:)`` in a tight loop, passing the next lane from the generated schedule. If a job for the preferred lane exists, it is returned; otherwise the queue falls back to any available job. This "prefer but don't block" policy means the generated schedule controls interleaving when multiple lanes have pending work, and automatically drains whichever lane is still active when others have no pending continuations.
///
/// Thread-safe: all mutable state is protected by `Mutex`. In the common case (single-threaded drain loop), the lock is uncontended. When a foreign executor re-enqueues a continuation from another thread, the lock serializes the access.
final class RunQueue: @unchecked Sendable {
    private var laneJobs: [[UnownedJob]]
    private var laneCursors: [Int]
    private var completedLanes: Set<LaneID> = []
    private let laneCount: Int
    private let lock = Mutex<Void>(())

    init(laneCount: Int) {
        self.laneCount = laneCount
        self.laneJobs = Array(repeating: [], count: laneCount)
        self.laneCursors = Array(repeating: 0, count: laneCount)
    }

    /// Appends a job to the specified lane's queue. May be called from any thread.
    func enqueue(lane: LaneID, job: UnownedJob) {
        lock.withLock { _ in laneJobs[Int(lane.index)].append(job) }
    }

    /// Records that a lane's task has finished executing all its commands.
    func markComplete(lane: LaneID) {
        _ = lock.withLock { _ in completedLanes.insert(lane) }
    }

    /// Returns true when all lanes have completed and no jobs remain.
    var isFinished: Bool {
        lock.withLock { _ in completedLanes.count == laneCount && pendingJobExists == false }
    }

    /// Returns true when at least one lane has a pending job.
    var hasPendingJobs: Bool {
        lock.withLock { _ in pendingJobExists }
    }

    /// Removes and returns the next job, preferring the specified lane. O(1) for the preferred lane, O(K) fallback where K is the lane count.
    ///
    /// Falls back to any available job if the preferred lane has none pending. Returns nil only when all lanes are empty.
    func dequeue(preferring preferred: LaneID) -> (lane: LaneID, job: UnownedJob)? {
        lock.withLock { _ in
            let prefIndex = Int(preferred.index)
            if laneCursors[prefIndex] < laneJobs[prefIndex].count {
                let job = laneJobs[prefIndex][laneCursors[prefIndex]]
                laneCursors[prefIndex] += 1
                return (preferred, job)
            }
            for laneIndex in 0 ..< laneCount {
                if laneCursors[laneIndex] < laneJobs[laneIndex].count {
                    let job = laneJobs[laneIndex][laneCursors[laneIndex]]
                    laneCursors[laneIndex] += 1
                    return (LaneID(index: UInt8(laneIndex)), job)
                }
            }
            return nil
        }
    }

    /// Returns true when the specified lane has at least one pending job.
    func hasPendingJob(for lane: LaneID) -> Bool {
        lock.withLock { _ in
            let index = Int(lane.index)
            return laneCursors[index] < laneJobs[index].count
        }
    }

    private var pendingJobExists: Bool {
        (0 ..< laneCount).contains { laneCursors[$0] < laneJobs[$0].count }
    }
}
