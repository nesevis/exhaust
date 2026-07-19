// MARK: - Cooperative Task Executor for Deterministic Interleaving

//
// This file implements a cooperative scheduling pattern identical to Swift's own CooperativeExecutor (stdlib/public/Concurrency/CooperativeExecutor.swift). N LaneExecutor instances share a single RunQueue. The drain loop, run synchronously by the calling thread, picks jobs from the queue based on a generated schedule and executes each via runSynchronously(on:).
//
// Key invariant: one runSynchronously call executes exactly one continuation, the synchronous code between two suspension points. When a task hits an `await`, the runtime re-enqueues the next continuation through LaneExecutor.enqueue(_:), which deposits it back into the RunQueue. The drain loop then picks the next job (potentially from another lane), producing deterministic sub-command interleaving at every await boundary.
//
// Thread safety: RunQueue is protected by an NSCondition lock. In the common case (all continuations flow through LaneExecutor on the drain loop thread), the lock is uncontended. The lock exists because SUTs commonly wrap GCD-based code in async/await facades (for example, a database that uses DispatchQueue internally but exposes an async API via withCheckedContinuation). When the SUT's GCD work completes, the continuation is re-enqueued to LaneExecutor from the GCD thread, not the drain loop thread. Without the lock, this concurrent enqueue races with the drain loop's dequeue on the per-lane arrays. Custom-executor actors and Task.sleep produce the same cross-thread re-enqueue pattern.
//
// These types are deliberately non-generic — they traffic in UnownedJob and UInt8 lane indices, never in command payloads — so the per-continuation machinery compiles as concrete code under this module's whole-module optimization. Spec-generic orchestration stays in the Exhaust module and calls in here once per probe.
import Foundation

/// Identifies a logical execution lane in a concurrent spec test.
///
/// Lane indices are zero-based: lane 0 is "a", lane 1 is "b", and so on up to the concurrency level minus one. The label maps index to a lowercase ASCII letter for trace output.
package struct LaneID: Hashable, Sendable {
    package let index: UInt8

    package init(index: UInt8) {
        self.index = index
    }

    package var label: String {
        String(UnicodeScalar(UInt8(ascii: "a") + index))
    }
}

/// Tags enqueued jobs with a lane identifier and deposits them into the shared ``RunQueue``.
///
/// Each concurrent spec test creates one LaneExecutor per lane, all sharing the same RunQueue. When a task with `executorPreference` set to this executor suspends and later resumes, the Swift runtime calls ``enqueue(_:)`` to schedule the next continuation. The lane tag lets the drain loop identify which lane produced the job without inspecting the job's content.
///
/// Marked `@unchecked Sendable` because ``enqueue(_:)`` may be called from any thread (when a continuation arrives from a foreign executor). Thread safety is provided by ``RunQueue``'s lock.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
package final class LaneExecutor: TaskExecutor, @unchecked Sendable {
    package let lane: LaneID
    package let runQueue: RunQueue

    package init(lane: LaneID, runQueue: RunQueue) {
        self.lane = lane
        self.runQueue = runQueue
    }

    package func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        if runQueue.enqueue(lane: lane, job: unownedJob) == false {
            runAfterAbandonment(unownedJob)
        }
    }

    /// Runs a continuation outside the deterministic drain after its probe has timed out and transferred cleanup ownership.
    package func runAfterAbandonment(_ job: UnownedJob) {
        DispatchQueue.global().async { [self] in
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }

    package func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}

/// Collects tagged jobs from all lane executors and dispatches them under schedule control.
///
/// The drain loop calls ``dequeue(preferring:)`` (or the consolidated ``dequeueOrStatus(preferring:)``), passing the next lane from the generated schedule. If a job for the preferred lane exists, it is returned; otherwise the queue falls back to any available job. This "prefer but don't block" policy means the generated schedule controls interleaving when multiple lanes have pending work, and automatically drains whichever lane is still active when others have no pending continuations.
///
/// Thread-safe: all mutable state is protected by `NSCondition`. In the common case (single-threaded drain loop), the lock is uncontended. When a foreign executor re-enqueues a continuation from another thread, the lock serializes the access. A queue-wide condition wakes the drain loop when it is parked with no runnable jobs; the condition does not participate in lane selection.
package final class RunQueue: @unchecked Sendable {
    private struct Lane {
        var jobs: [UnownedJob] = []
        var cursor: Int = 0
        var isComplete: Bool = false

        var hasPendingJob: Bool {
            cursor < jobs.count
        }
    }

    private var lanes: [Lane]
    private let condition = NSCondition()
    private var isAbandoned = false

    package init(laneCount: Int) {
        lanes = Array(repeating: Lane(), count: laneCount)
    }

    /// Appends a job to the specified lane's queue. May be called from any thread.
    package func enqueue(lane: LaneID, job: UnownedJob) -> Bool {
        withLocking {
            guard isAbandoned == false else {
                return false
            }
            lanes[Int(lane.index)].jobs.append(job)
            condition.signal()
            return true
        }
    }

    /// Transfers pending and future continuations out of the deterministic drain after timeout.
    ///
    /// Pending jobs are returned to the caller for immediate scheduling. Future jobs make ``enqueue(lane:job:)`` return `false`, which tells their ``LaneExecutor`` to schedule them directly. This breaks the executor/task/queue retention cycle without waiting through a second idle-timeout window.
    package func abandon() -> [(lane: LaneID, job: UnownedJob)] {
        withLocking {
            guard isAbandoned == false else {
                return []
            }
            isAbandoned = true
            var pending: [(lane: LaneID, job: UnownedJob)] = []
            for laneIndex in lanes.indices {
                let lane = lanes[laneIndex]
                for jobIndex in lane.cursor ..< lane.jobs.count {
                    pending.append((LaneID(index: UInt8(laneIndex)), lane.jobs[jobIndex]))
                }
                lanes[laneIndex].jobs.removeAll(keepingCapacity: false)
                lanes[laneIndex].cursor = 0
                lanes[laneIndex].isComplete = true
            }
            condition.broadcast()
            return pending
        }
    }

    /// Records that a lane's task has finished executing all its commands.
    ///
    /// Signals the condition and, together with the all-lanes-complete check in ``waitForJob(until:)``, releases a parked drain loop so it observes the finished state rather than waiting out the idle timeout. Today this is belt-and-braces: completion always runs on the drain thread (lane tasks carry `executorPreference`, so the terminal continuation routes back here), so the loop is never parked when a lane completes. The pairing keeps the drain loop live if a future change ever marks a lane complete from another thread.
    package func markComplete(lane: LaneID) {
        withLocking {
            lanes[Int(lane.index)].isComplete = true
            condition.signal()
        }
    }

    /// The combined outcome of one drain-loop poll: a job to run, an empty-but-unfinished queue, or completion.
    ///
    /// Exists so the drain loop's finished-check, pending-check, and dequeue happen under a single lock acquisition per drained continuation instead of three. ``ScheduleDrain/drainConcurrentSection(runQueue:executors:schedule:concurrencyLevel:idleTimeoutMilliseconds:failureFlag:onTraceSignal:)`` is the intended caller.
    package enum DequeueOutcome {
        /// A job is available; the lane is where it came from (preferred lane when possible, any pending lane otherwise).
        case job(lane: LaneID, job: UnownedJob)
        /// No lane has a pending job, but not every lane has completed — the drain loop should park and wait.
        case empty
        /// Every lane has completed and no jobs remain.
        case finished
    }

    /// Removes and returns the next job, preferring the specified lane, or reports the queue's status when no job is pending — all under one lock acquisition.
    package func dequeueOrStatus(preferring preferred: LaneID) -> DequeueOutcome {
        withLocking {
            let preferredIndex = Int(preferred.index)
            if lanes[preferredIndex].hasPendingJob {
                let job = lanes[preferredIndex].jobs[lanes[preferredIndex].cursor]
                lanes[preferredIndex].cursor += 1
                return .job(lane: preferred, job: job)
            }
            for laneIndex in lanes.indices where lanes[laneIndex].hasPendingJob {
                let job = lanes[laneIndex].jobs[lanes[laneIndex].cursor]
                lanes[laneIndex].cursor += 1
                return .job(lane: LaneID(index: UInt8(laneIndex)), job: job)
            }
            return lanes.allSatisfy(\.isComplete) ? .finished : .empty
        }
    }

    /// Removes and returns the next job, preferring the specified lane. O(1) for the preferred lane, O(K) fallback where K is the lane count.
    ///
    /// Falls back to any available job if the preferred lane has none pending. Returns nil only when all lanes are empty. Single-lane drain loops use this; the schedule-following loop uses ``dequeueOrStatus(preferring:)`` to fold the finished-check into the same lock acquisition.
    package func dequeue(preferring preferred: LaneID) -> (lane: LaneID, job: UnownedJob)? {
        withLocking {
            let preferredIndex = Int(preferred.index)
            if lanes[preferredIndex].hasPendingJob {
                let job = lanes[preferredIndex].jobs[lanes[preferredIndex].cursor]
                lanes[preferredIndex].cursor += 1
                return (preferred, job)
            }
            for laneIndex in lanes.indices where lanes[laneIndex].hasPendingJob {
                let job = lanes[laneIndex].jobs[lanes[laneIndex].cursor]
                lanes[laneIndex].cursor += 1
                return (LaneID(index: UInt8(laneIndex)), job)
            }
            return nil
        }
    }

    /// Returns true when the specified lane has at least one pending job.
    package func hasPendingJob(for lane: LaneID) -> Bool {
        withLocking { lanes[Int(lane.index)].hasPendingJob }
    }

    /// Waits until at least one job is enqueued (or every lane completes), or until the deadline expires.
    ///
    /// Callers should attempt a dequeue before and after waiting. The condition only avoids empty-queue spin; the queue's normal preference and fallback logic still decides which job runs. Returns `true` on either a new job or all-lanes-complete so the drain loop loops back and re-checks the finished state; returns `false` only on a genuine idle timeout. The all-complete check makes the wait safe even if a lane is ever marked complete from off the drain thread (see ``markComplete(lane:)``).
    package func waitForJob(until deadline: Date) -> Bool {
        withLocking {
            while lanes.contains(where: \.hasPendingJob) == false {
                if lanes.allSatisfy(\.isComplete) {
                    return true
                }
                if condition.wait(until: deadline) == false {
                    return lanes.contains(where: \.hasPendingJob) || lanes.allSatisfy(\.isComplete)
                }
            }
            return true
        }
    }

    /// Waits for the remainder of an idle-timeout window.
    ///
    /// Returns `false` when the idle timeout expires before another job is enqueued.
    package func waitForJob(
        idleTimeoutMilliseconds: Int,
        elapsedMilliseconds: Double
    ) -> Bool {
        if idleTimeoutMilliseconds == Int.max {
            waitForJob()
            return true
        }

        let remainingMilliseconds = idleTimeoutMilliseconds - Int(elapsedMilliseconds)
        guard remainingMilliseconds > 0 else {
            return false
        }

        return waitForJob(
            until: Date(timeIntervalSinceNow: Double(remainingMilliseconds) / 1000)
        )
    }

    /// Waits until at least one job is enqueued, or every lane completes.
    package func waitForJob() {
        withLocking {
            while lanes.contains(where: \.hasPendingJob) == false {
                if lanes.allSatisfy(\.isComplete) {
                    return
                }
                condition.wait()
            }
        }
    }

    private func withLocking<Result>(_ body: () throws -> Result) rethrows -> Result {
        condition.lock()
        defer { condition.unlock() }
        return try body()
    }
}
