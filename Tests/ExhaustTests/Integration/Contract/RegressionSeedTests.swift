import Testing
@testable import Exhaust

@Suite("Contract regression seed tests", .serialized, .tags(.contract))
struct RegressionSeedTests {
    // A zero budget makes the normal coverage/sampling run find nothing, so a non-nil
    // result proves the regression seed itself reproduced the failure. The `-N` (sampling)
    // and `U…` (coverage-row) formats are the exact strings the runner prints; before the
    // fix the regression decoder rejected both, so these seeds would silently no-op.

    @Test(
        "Sequential regression seed reproduces a sampling failure through the trait",
        .exhaust(.regressions("FZ9CGDYNJAFDV-2"))
    )
    func sequentialRegressionSeedReproduces() {
        let result = #execute(
            RegressionCounterContract.self,
            .commandLimit(8),
            .budget(.custom(coverage: 0, sampling: 0)),
            .suppress(.issueReporting)
        )
        #expect(result != nil, "regression seed should reproduce the failure on its own")
    }

    @Test(
        "Cooperative regression seed reproduces a sampling failure through the trait",
        .exhaust(.regressions("EJN23PCJKT2AS-5"))
    )
    func cooperativeRegressionSeedReproduces() async {
        let result = await #execute(
            RegressionCounterCooperativeContract.self,
            .concurrent(.two),
            .commandLimit(6),
            .budget(.custom(coverage: 0, sampling: 0)),
            .suppress(.issueReporting)
        )
        #expect(result != nil, "regression seed should reproduce the failure on its own")
    }

    @Test("Preemptive regression seed reproduces a failure through the trait")
    func preemptiveRegressionSeedReproduces() throws {
        let initial = try #require(
            __ExhaustRuntime.__runPreemptiveConcurrentContract(
                RegressionPreemptiveContract.self,
                settings: [.commandLimit(6), .suppress(.all)]
            )
        )
        let replaySeed = try #require(initial.replaySeed)

        let result = ExhaustTraitConfiguration.$current.withValue(
            ExhaustTraitConfiguration(budget: nil, regressions: [replaySeed])
        ) {
            __ExhaustRuntime.__runPreemptiveConcurrentContract(
                RegressionPreemptiveContract.self,
                settings: [
                    .commandLimit(6),
                    .budget(.custom(coverage: 0, sampling: 0)),
                    .suppress(.all),
                ]
            )
        }
        #expect(result != nil, "regression seed should reproduce the failure on its own")
    }

    @Test("Async sequential regression seed reproduces a sampling failure through the trait")
    func asyncSequentialRegressionSeedReproduces() async throws {
        let initial = try #require(
            await __ExhaustRuntime.__runContractAsync(
                RegressionAsyncSequentialContract.self,
                settings: [
                    .commandLimit(8),
                    .budget(.custom(coverage: 0, sampling: 200)),
                    .suppress(.all),
                ]
            )
        )
        let replaySeed = try #require(initial.replaySeed)

        let result = await ExhaustTraitConfiguration.$current.withValue(
            ExhaustTraitConfiguration(budget: nil, regressions: [replaySeed])
        ) {
            await __ExhaustRuntime.__runContractAsync(
                RegressionAsyncSequentialContract.self,
                settings: [
                    .commandLimit(8),
                    .budget(.custom(coverage: 0, sampling: 1)),
                    .suppress(.all),
                ]
            )
        }
        #expect(result != nil, "regression seed should reproduce the failure on its own")
    }
}

// MARK: - Specs

@Contract(.sequential)
private final class RegressionCounterContract {
    var expected: Int = 0
    @SystemUnderTest var counter = RegressionCounter()

    @Invariant
    func valueMatches() -> Bool {
        counter.value == expected
    }

    @Command(weight: 3)
    func increment() throws {
        expected += 1
        counter.increment()
    }

    @Command(weight: 2)
    func decrement() throws {
        guard expected > 0 else {
            throw skip()
        }
        expected -= 1
        counter.decrement()
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

@Contract(.tasks)
private final class RegressionCounterCooperativeContract {
    var expected: Int = 0
    @SystemUnderTest var counter = RegressionRacyCounter()

    @Invariant
    func valueMatches() -> Bool {
        counter.value == expected
    }

    @Command(weight: 3)
    func increment() async throws {
        expected += 1
        await counter.increment()
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

// MARK: - Supporting Types

private final class RegressionCounter {
    private(set) var value: Int = 0

    func increment() {
        value += 1
    }

    func decrement() {
        // Bug: decrement is a no-op once value reaches 3.
        if value != 3 {
            value -= 1
        }
    }
}

private final class RegressionRacyCounter: @unchecked Sendable, CustomDebugStringConvertible {
    private var storedValue: Int = 0
    var value: Int {
        storedValue
    }

    var debugDescription: String {
        "RegressionRacyCounter(value: \(storedValue))"
    }

    func increment() async {
        let current = storedValue
        await Task.yield()
        storedValue = current + 1
    }
}

@Contract(.threads)
private final class RegressionPreemptiveContract {
    var expected: Int = 0
    @SystemUnderTest var counter = RegressionBrokenDecrement()

    @Oracle
    func oracleMatches(other: RegressionBrokenDecrement) -> Bool {
        counter.value == other.value
    }

    @Invariant
    func valueMatches() -> Bool {
        counter.value == expected
    }

    @Command(weight: 3)
    func increment() throws {
        expected += 1
        counter.increment()
    }

    @Command(weight: 2)
    func decrement() throws {
        guard expected > 0 else {
            throw skip()
        }
        expected -= 1
        counter.decrement()
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

private final class RegressionBrokenDecrement: @unchecked Sendable, CustomDebugStringConvertible {
    private var storedValue: Int = 0
    var value: Int {
        storedValue
    }

    var debugDescription: String {
        "RegressionBrokenDecrement(\(storedValue))"
    }

    func increment() {
        storedValue += 1
    }

    func decrement() {
        // Bug: no-op when value is 1.
        if storedValue != 1 {
            storedValue -= 1
        }
    }
}

@Contract(.sequential)
private final class RegressionAsyncSequentialContract {
    var expected: Int = 0
    @SystemUnderTest var counter = RegressionAsyncCounter()

    @Invariant
    func valueMatches() -> Bool {
        counter.value == expected
    }

    @Command(weight: 3)
    func increment() async throws {
        expected += 1
        counter.increment()
    }

    @Command(weight: 2)
    func decrement() async throws {
        guard expected > 0 else {
            throw skip()
        }
        expected -= 1
        counter.decrement()
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

private final class RegressionAsyncCounter {
    private(set) var value: Int = 0

    func increment() {
        value += 1
    }

    func decrement() {
        // Bug: no-op when value is 3.
        if value != 3 {
            value -= 1
        }
    }
}
