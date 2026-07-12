import ExhaustCore
import Testing

@Suite("ReductionPool bounded concurrency tests")
struct ReductionPoolTests {
    @Test("All submitted work completes and drain waits for it")
    func drainCompletes() async {
        let pool = ReductionPool(maxConcurrent: 2)
        let counter = Counter()
        for _ in 0 ..< 20 {
            pool.submit {
                await counter.increment()
            }
        }
        #expect(pool.drain(timeoutNanoseconds: 5_000_000_000))
        #expect(await counter.value == 20)
    }

    @Test("Concurrency never exceeds the cap")
    func concurrencyBounded() async {
        let pool = ReductionPool(maxConcurrent: 3)
        let tracker = ConcurrencyTracker()
        for _ in 0 ..< 30 {
            pool.submit {
                await tracker.enter()
                try? await Task.sleep(nanoseconds: 1_000_000)
                await tracker.exit()
            }
        }
        #expect(pool.drain(timeoutNanoseconds: 5_000_000_000))
        #expect(await tracker.peak <= 3)
        #expect(await tracker.total == 30)
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
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        #expect(pool.drain(timeoutNanoseconds: 1_000_000) == false)
        #expect(pool.drain(timeoutNanoseconds: 5_000_000_000))
    }
}

// MARK: - Helpers

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor ConcurrencyTracker {
    private var current = 0
    private(set) var peak = 0
    private(set) var total = 0

    func enter() {
        current += 1
        peak = max(peak, current)
        total += 1
    }

    func exit() {
        current -= 1
    }
}
