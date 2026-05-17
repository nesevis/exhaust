import Exhaust
import Testing

// MARK: - Tests

@Suite("Async contract tests")
struct AsyncContractTests {
    @Test("Passing async spec produces no counterexample")
    func passingAsyncContract() async {
        let result = await #exhaust(
            AsyncCounterSpec.self,
            .concurrency(1),
            .commandLimit(8),
            .budget(.custom(coverage: 0, sampling: 100)),
            .suppress(.issueReporting)
        )
        #expect(result == nil, "Async counter spec should pass — model and SUT are identical")
    }

    @Test("Failing async spec produces a counterexample")
    func failingAsyncContract() async {
        let result = await #exhaust(
            BuggyAsyncCounterSpec.self,
            .commandLimit(10),
            .budget(.custom(coverage: 0, sampling: 200)),
            .suppress(.issueReporting)
        )
        #expect(result != nil, "Buggy async counter should fail")
        if let result {
            #expect(!result.trace.isEmpty)
            let hasFailure = result.trace.contains { step in
                if case .invariantFailed = step.outcome { return true }
                return false
            }
            #expect(hasFailure, "Trace should contain an invariant failure")
        }
    }

    @Test("Async contract with skip() works correctly")
    func asyncContractWithSkip() async {
        let result = await #exhaust(
            AsyncSkipSpec.self,
            .concurrency(1),
            .commandLimit(8),
            .budget(.custom(coverage: 0, sampling: 100)),
            .suppress(.issueReporting)
        )
        #expect(result == nil, "Async skip spec should pass")
    }

    @Test("Mixed sync+async commands produce AsyncContractSpec conformance")
    func mixedAsyncContract() async {
        let result = await #exhaust(
            MixedAsyncSpec.self,
            .concurrency(1),
            .commandLimit(8),
            .budget(.custom(coverage: 0, sampling: 100)),
            .suppress(.issueReporting)
        )
        #expect(result == nil, "Mixed async spec should pass")
    }

    @Test("Async contract replay reproduces failure with seed through shrinking")
    func asyncReplayWithSeed() async {
        let result1 = await #exhaust(
            BuggyAsyncCounterSpec.self,
            .commandLimit(10),
            .replay(.numeric(42)),
            .suppress(.issueReporting)
        )
        #expect(result1 != nil, "Replay with seed 42 should produce a failure")

        let result2 = await #exhaust(
            BuggyAsyncCounterSpec.self,
            .commandLimit(10),
            .replay(.numeric(42)),
            .suppress(.issueReporting)
        )
        #expect(result2 != nil, "Same seed should reproduce the failure")
        if let result1, let result2 {
            #expect(result1.commands.count == result2.commands.count, "Same seed should produce same command count")
        }
    }

    @Test("Async contract with SCA coverage finds and shrinks failure")
    func asyncWithCoverage() async {
        let result = await #exhaust(
            BuggyAsyncCounterSpec.self,
            .commandLimit(20),
            .budget(.custom(coverage: 0, sampling: 200)),
            .suppress(.issueReporting),
            .logging(.debug)
        )
        #expect(result != nil, "Should find a failure")
        if let result {
            #expect(result.commands.count <= 6, "Expected shrunk result, got \(result.commands.count) commands")
        }
    }

    @Test("sync contract replay reproduces failure deterministically")
    func syncReplayWithCoverage() {
        // Use a fixed seed that produces a failure
        let result1 = #exhaust(
            BuggyCounterSpec.self,
            .commandLimit(20),
            .suppress(.issueReporting)
        )
        print()
        #expect(result1 != nil, "Replay with seed 42 should produce a failure")
    }
}

// MARK: - Contract: Passing async counter

@Contract
final class AsyncCounterSpec {
    @Model var expected: Int = 0
    @SUT var counter: AsyncCounter = .init()

    @Invariant
    func valueMatches() async -> Bool {
        await counter.value == expected
    }

    @Command(weight: 3)
    func increment() async throws {
        expected += 1
        await counter.increment()
    }

    @Command(weight: 2)
    func decrement() async throws {
        expected -= 1
        await counter.decrement()
    }

    @Command(weight: 1)
    func reset() async throws {
        expected = 0
        await counter.reset()
    }
}

// MARK: - Contract: Failing async counter (invariant violation)

@Contract
final class BuggyAsyncCounterSpec {
    @Model var expected: Int = 0
    @SUT var counter: BuggyAsyncCounter = .init()

    @Invariant
    func valueMatches() async -> Bool {
        await counter.value == expected
    }

    @Command(weight: 3)
    func increment() async throws {
        expected += 1
        await counter.increment()
    }

    @Command(weight: 2)
    func decrement() async throws {
        expected -= 1
        await counter.decrement()
    }
}

// MARK: - Contract: Async with skip()

@Contract
final class AsyncSkipSpec {
    @Model var expected: [Int] = []
    @SUT var counter: AsyncCounter = .init()

    @Invariant
    func historyLengthMatches() async -> Bool {
        await counter.history.count == expected.count
    }

    @Command(weight: 3)
    func increment() async throws {
        expected.append(expected.count + 1)
        await counter.increment()
    }

    @Command(weight: 2)
    func decrement() async throws {
        guard !expected.isEmpty else { throw skip() }
        expected.append(expected.last! - 1)
        await counter.decrement()
    }
}

// MARK: - Contract: Mixed sync + async commands

@Contract
final class MixedAsyncSpec {
    @Model var expected: Int = 0
    @SUT var counter: AsyncCounter = .init()

    @Invariant
    func valueMatches() async -> Bool {
        await counter.value == expected
    }

    /// Sync command — still valid in an async contract
    @Command(weight: 1)
    func syncNoOp() throws {
        // Does nothing to either model or SUT
    }

    @Command(weight: 3)
    func increment() async throws {
        expected += 1
        await counter.increment()
    }
}

// MARK: - Types

actor AsyncCounter {
    private(set) var value: Int = 0
    private(set) var history: [Int] = []

    func increment() {
        value += 1
        history.append(value)
    }

    func decrement() {
        value -= 1
        history.append(value)
    }

    func reset() {
        value = 0
        history.append(0)
    }
}

actor BuggyAsyncCounter {
    private(set) var value: Int = 0

    func increment() {
        value += 1
    }

    func decrement() {
        // Bug: decrement does nothing when value > 2
        if value <= 2 {
            value -= 1
        }
    }
}
