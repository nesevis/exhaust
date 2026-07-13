// The concurrent half of reduction backpressure; the synchronous half is ReductionGate.

import Foundation

/// Runs reduction work on the global GCD queue with bounded concurrency; overflow queues FIFO.
///
/// Lock-based rather than actor-isolated so the synchronous exploration loop can `submit` without suspending, preserving FIFO dispatch order. In-flight reduction cost stays bounded relative to exploration regardless of failure rate; the cap comes from ``FuzzTunables/maxConcurrentReductions``.
///
/// Reductions run on GCD rather than the cooperative pool because they are CPU-bound (the reducer's graph walk), block on `NSLock` (the attribution token during post-reduction signature capture), and never suspend. Occupying cooperative-pool threads with blocking work risks exhausting the pool under parallel test execution.
package final class ReductionPool: @unchecked Sendable {
    // @unchecked: all mutable state is guarded by `condition`.
    private static let dispatchQueue = DispatchQueue(
        label: "com.exhaust.reduction",
        qos: .utility,
        attributes: .concurrent
    )

    private let condition = NSCondition()
    let maxConcurrent: Int
    private var running = 0
    private var queue: [@Sendable () -> Void] = []

    /// Creates a pool with the given concurrency cap (defaults to the tunable).
    package init(maxConcurrent: Int = FuzzTunables.maxConcurrentReductions) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Submits one reduction; starts it immediately when a slot is free, otherwise queues it FIFO.
    package func submit(_ work: @escaping @Sendable () -> Void) {
        condition.lock()
        if running < maxConcurrent {
            running += 1
            condition.unlock()
            start(work)
        } else {
            queue.append(work)
            condition.unlock()
        }
    }

    private func start(_ work: @escaping @Sendable () -> Void) {
        Self.dispatchQueue.async {
            work()
            self.finishOne()
        }
    }

    private func finishOne() {
        condition.lock()
        if queue.isEmpty == false {
            let next = queue.removeFirst()
            condition.unlock()
            start(next)
            return
        }
        running -= 1
        if running == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    /// Blocks the calling thread until every submitted reduction (running and queued) completes or the timeout elapses.
    ///
    /// Called once, at end of run, from the GCD lane that owns the exploration loop — never from a cooperative-pool thread. Returns `false` on timeout, in which case still-running reductions are reported as unreduced.
    package func drain(timeoutNanoseconds: UInt64) -> Bool {
        let deadline = Date(timeIntervalSinceNow: Double(timeoutNanoseconds) / 1_000_000_000)
        condition.lock()
        defer { condition.unlock() }
        while running > 0 || queue.isEmpty == false {
            guard condition.wait(until: deadline) else {
                return false
            }
        }
        return true
    }
}
