import Exhaust
import Testing

// MARK: - Tests

@Suite("Concurrent contract tests")
struct ConcurrentContractTests {
    @Test("Detects lost-update bug in non-atomic counter")
    func detectsLostUpdate() async throws {
        let result = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                commandLimit: 4,
                scheduleLength: 20,
                budget: .custom(coverage: 0, sampling: 200),
                suppressIssueReporting: true
            )
        )
        let hasFailure = result.trace.contains { step in
            if case .invariantFailed = step.outcome { return true }
            if case .checkFailed = step.outcome { return true }
            return false
        }
        #expect(hasFailure, "Should detect invariant failure from interleaved read-modify-write")
    }

    @Test("Thread-safe counter passes under all interleavings")
    func atomicCounterPasses() async {
        let result = await __runContractConcurrent(
            AtomicCounterSpec.self,
            commandLimit: 4,
            scheduleLength: 20,
            budget: .custom(coverage: 0, sampling: 200),
            suppressIssueReporting: true
        )
        #expect(result == nil, "Atomic counter should pass under any interleaving")
    }

    @Test("Reduced counterexample is smaller than original")
    func reductionShrinks() async throws {
        let result = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                commandLimit: 6,
                scheduleLength: 30,
                budget: .custom(coverage: 0, sampling: 200),
                suppressIssueReporting: true
            )
        )
        #expect(result.commands.count <= 6, "Reducer should shrink the counterexample")
    }

    @Test("Detects check-then-act bug that requires state buildup")
    func detectsLeakyBucket() async throws {
        let result = try #require(
            await __runContractConcurrent(
                LeakyBucketSpec.self,
                commandLimit: 8,
                scheduleLength: 40,
                budget: .custom(coverage: 0, sampling: 500),
                suppressIssueReporting: false
            )
        )
        let hasFailure = result.trace.contains { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        }
        #expect(hasFailure, "Should detect token over-drain from interleaved tryConsume")
    }

    @Test("Deterministic replay produces same result")
    func deterministicReplay() async throws {
        let result1 = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                commandLimit: 4,
                scheduleLength: 20,
                budget: .custom(coverage: 0, sampling: 200),
                seed: 42,
                suppressIssueReporting: true
            )
        )
        let result2 = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                commandLimit: 4,
                scheduleLength: 20,
                budget: .custom(coverage: 0, sampling: 200),
                seed: 42,
                suppressIssueReporting: true
            )
        )
        #expect(result1.commands.count == result2.commands.count, "Same seed should produce same counterexample size")
    }
}

// MARK: - Contract: Non-atomic counter (lost-update bug)

/// The SUT has a non-atomic read-modify-write: `let v = _value; await yield(); _value = v + 1`.
/// When the executor interleaves at the yield, both tasks read the same stale value, producing a
/// lost update that the model detects.
@Contract
final class NonAtomicCounterSpec {
    @Model var expected: Int = 0
    @SUT var counter: NonAtomicCounter = .init()

    @Invariant
    func matchesModel() -> Bool {
        counter.value == expected
    }

    @Command(weight: 3)
    func increment() async throws {
        expected += 1
        await counter.increment()
    }

    @Command(weight: 2)
    func decrement() async throws {
        guard expected > 0 else { throw skip() }
        expected -= 1
        await counter.decrement()
    }
}

// MARK: - Contract: Leaky bucket (bug requires state buildup)

/// A rate limiter that only fails under concurrent access when the bucket is nearly full.
/// The bug: `tryConsume` does a non-atomic check-then-decrement. Under sequential access this
/// is fine because the check and decrement are never interleaved. Under concurrent access, both
/// tasks can pass the check, then both decrement — draining past the limit.
///
/// This requires multiple `refill` commands to build up the bucket level before the concurrent
/// `tryConsume` calls can trigger the over-drain.
@Contract
final class LeakyBucketSpec {
    @Model var expectedTokens: Int = 0
    @SUT var bucket: LeakyBucket = .init(capacity: 5)

    @Invariant
    func tokensNeverNegative() -> Bool {
        bucket.tokens >= 0
    }

    @Invariant
    func matchesModel() -> Bool {
        bucket.tokens == expectedTokens
    }

    @Command(weight: 4)
    func refill() async throws {
        guard expectedTokens < 5 else { throw skip() }
        expectedTokens += 1
        await bucket.refill()
    }

    @Command(weight: 3)
    func tryConsume() async throws {
        guard expectedTokens > 0 else { throw skip() }
        expectedTokens -= 1
        await bucket.tryConsume()
    }
}

// MARK: - Contract: Thread-safe counter (should always pass)

@Contract
final class AtomicCounterSpec {
    @Model var expected: Int = 0
    @SUT var counter: AtomicCounter = .init()

    @Invariant
    func matchesModel() -> Bool {
        counter.value == expected
    }

    @Command(weight: 3)
    func increment() async throws {
        expected += 1
        await counter.increment()
    }

    @Command(weight: 2)
    func decrement() async throws {
        guard expected > 0 else { throw skip() }
        expected -= 1
        await counter.decrement()
    }
}

// MARK: - SUTs

/// Non-atomic read-modify-write. The `await Task.yield()` between read and write is the
/// interleaving point where the executor can switch to the other task.
final class NonAtomicCounter: @unchecked Sendable {
    private var _value: Int = 0

    var value: Int { _value }

    func increment() async {
        let current = _value
        await Task.yield()
        _value = current + 1
    }

    func decrement() async {
        let current = _value
        await Task.yield()
        _value = current - 1
    }
}

/// A rate limiter with a non-atomic check-then-act bug in `tryConsume`. The bug only manifests
/// when tokens > 0 (requires prior refills) and two concurrent tryConsume calls interleave at
/// the yield between checking the count and decrementing.
final class LeakyBucket: @unchecked Sendable {
    private var _tokens: Int = 0
    private let _capacity: Int

    init(capacity: Int) { _capacity = capacity }

    var tokens: Int { _tokens }

    func refill() async {
        guard _tokens < _capacity else { return }
        _tokens += 1
    }

    func tryConsume() async {
        let current = _tokens
        guard current > 0 else { return }
        await Task.yield()
        _tokens = current - 1
    }
}

/// Atomic counter — operations are not split across await boundaries.
final class AtomicCounter: @unchecked Sendable {
    private var _value: Int = 0

    var value: Int { _value }

    func increment() async {
        _value += 1
    }

    func decrement() async {
        _value -= 1
    }
}
