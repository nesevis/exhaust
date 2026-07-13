import ExhaustCore
import Foundation
import Testing

@Suite("ReductionPool bounded concurrency tests")
struct ReductionPoolTests {
    @Test("All submitted work completes and drain waits for it")
    func drainCompletes() {
        let pool = ReductionPool(maxConcurrent: 2)
        let counter = AtomicCounter()
        for _ in 0 ..< 20 {
            pool.submit {
                counter.increment()
            }
        }
        #expect(pool.drain(timeoutNanoseconds: 5_000_000_000))
        #expect(counter.value == 20)
    }

    @Test("Concurrency never exceeds the cap")
    func concurrencyBounded() {
        let pool = ReductionPool(maxConcurrent: 3)
        let tracker = ConcurrencyTracker()
        for _ in 0 ..< 30 {
            pool.submit {
                tracker.enter()
                Thread.sleep(forTimeInterval: 0.001)
                tracker.exit()
            }
        }
        #expect(pool.drain(timeoutNanoseconds: 5_000_000_000))
        #expect(tracker.peak <= 3)
        #expect(tracker.total == 30)
    }

    @Test("Drain on an idle pool returns immediately")
    func drainIdle() {
        let pool = ReductionPool(maxConcurrent: 2)
        #expect(pool.drain(timeoutNanoseconds: 1_000_000))
    }

    @Test("Drain times out while work is still running")
    func drainTimeout() {
        let pool = ReductionPool(maxConcurrent: 1)
        pool.submit {
            Thread.sleep(forTimeInterval: 0.2)
        }
        #expect(pool.drain(timeoutNanoseconds: 1_000_000) == false)
        #expect(pool.drain(timeoutNanoseconds: 5_000_000_000))
    }
}

// MARK: - Helpers

private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.withLocking { _value }
    }

    func increment() {
        lock.withLocking { _value += 1 }
    }
}

private final class ConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var peak = 0
    private(set) var total = 0

    func enter() {
        lock.withLocking {
            current += 1
            peak = max(peak, current)
            total += 1
        }
    }

    func exit() {
        lock.withLocking {
            current -= 1
        }
    }
}
