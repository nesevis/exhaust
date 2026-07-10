// Backpressure between failure discovery and reduction dispatch.
//
// Densification deliberately steers sprawl back into failing regions, so a hot fault produces
// failures at a high rate; unbounded Task-per-failure dispatch would let in-flight reductions
// outconsume exploration. The gate is the synchronous half of the defence (dedup + per-symptom
// cap); the bounded reduction pool is the asynchronous half.

import Foundation

/// Decides synchronously, on the exploration loop, whether a failure earns a reduction dispatch.
package struct ReductionGate {
    /// The gate's verdict for one failure.
    package enum Verdict: Equatable {
        /// Dispatch a reduction Task.
        case reduce
        /// Record the failure as an unreduced cluster member; its symptom's cap is reached.
        case recordUnreduced
        /// A failure with an identical choice sequence was already dispatched; drop it entirely.
        case duplicate
    }

    private var dispatchedHashes: Set<UInt64> = []
    private var dispatchedCountsBySymptom: [FailureSymptom: Int] = [:]
    private var seenCountsBySymptom: [FailureSymptom: Int] = [:]

    package init() {}

    /// Evaluates one failure. Mutates the gate's counters according to the verdict, so call exactly once per failure.
    ///
    /// The per-symptom cap uses *dispatched* counts as a synchronous proxy for the cluster's reduced count — classifications complete asynchronously and the gate cannot wait for them. Symptom matching is exactly the weak signal the inventory distrusts, so every K-th capped failure is reduced anyway, bounding the risk of a genuinely new bug hiding behind a familiar symptom.
    package mutating func admit(sequenceHash: UInt64, symptom: FailureSymptom) -> Verdict {
        guard dispatchedHashes.contains(sequenceHash) == false else {
            return .duplicate
        }
        seenCountsBySymptom[symptom, default: 0] += 1
        let dispatched = dispatchedCountsBySymptom[symptom, default: 0]
        if dispatched >= SprawlTunables.perClusterReductionCap {
            let seen = seenCountsBySymptom[symptom, default: 0]
            guard seen % SprawlTunables.reductionEscapeInterval == 0 else {
                return .recordUnreduced
            }
        }
        dispatchedHashes.insert(sequenceHash)
        dispatchedCountsBySymptom[symptom, default: 0] = dispatched + 1
        return .reduce
    }
}

/// Runs reduction work with bounded concurrency; overflow queues FIFO.
///
/// Lock-based rather than actor-isolated so the synchronous exploration loop can `submit` without suspending, preserving FIFO dispatch order. In-flight reduction cost stays bounded relative to exploration regardless of failure rate; the cap comes from ``SprawlTunables/maxConcurrentReductions``.
package final class ReductionPool: @unchecked Sendable {
    // @unchecked: all mutable state is guarded by `condition`.
    private let condition = NSCondition()
    private let maxConcurrent: Int
    private var running = 0
    private var queue: [@Sendable () async -> Void] = []

    /// Creates a pool with the given concurrency cap (defaults to the tunable).
    package init(maxConcurrent: Int = SprawlTunables.maxConcurrentReductions) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Submits one reduction; starts it immediately when a slot is free, otherwise queues it FIFO.
    package func submit(_ work: @escaping @Sendable () async -> Void) {
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

    private func start(_ work: @escaping @Sendable () async -> Void) {
        Task {
            await work()
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
