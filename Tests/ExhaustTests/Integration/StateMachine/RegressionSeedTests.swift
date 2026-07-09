import Foundation
import Testing
@testable import Exhaust

@Suite("Spec regression seed tests", .serialized, .tags(.stateMachine))
struct RegressionSeedTests {
    // A zero budget makes the normal coverage/sampling run find nothing, so a non-nil
    // result proves the regression seed itself reproduced the failure. The `-N` (sampling)
    // and `U…` (coverage-row) formats are the exact strings the runner prints; before the
    // fix the regression decoder rejected both, so these seeds would silently no-op.

    @Test(
        "Sequential regression seed reproduces a sampling failure through the trait",
        .exhaust(.regressions("FZ9CGDYNJAFDV-2"))
    )
    func sequentialRegressionSeedReproduces() async {
        let result = await #execute(
            RegressionCounterSpec.self,
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
            RegressionCounterCooperativeSpec.self,
            .parallelize(lanes: .two),
            .commandLimit(6),
            .budget(.custom(coverage: 0, sampling: 0)),
            .suppress(.issueReporting)
        )
        #expect(result != nil, "regression seed should reproduce the failure on its own")
    }

    @Test("Preemptive regression seed reproduces a failure through the trait")
    func preemptiveRegressionSeedReproduces() async throws {
        let initial = try #require(
            await #execute(
                RegressionPreemptiveSpec.self,
                .commandLimit(20),
                .suppress(.all)
            )
        )
        let replaySeed = try #require(initial.replaySeed)

        let result = await ExhaustTraitConfiguration.$current.withValue(
            ExhaustTraitConfiguration(budget: nil, regressions: [replaySeed])
        ) {
            await #execute(
                RegressionPreemptiveSpec.self,
                .commandLimit(20),
                .suppress(.all)
            )
        }
        #expect(result != nil, "regression seed should reproduce the failure on its own")
    }

    @Test("Async sequential regression seed reproduces a sampling failure through the trait")
    func asyncSequentialRegressionSeedReproduces() async throws {
        let initial = try #require(
            await #execute(
                RegressionAsyncSequentialSpec.self,
                .commandLimit(8),
                .budget(.custom(coverage: 0, sampling: 200)),
                .suppress(.all)
            )
        )
        let replaySeed = try #require(initial.replaySeed)

        let result = await ExhaustTraitConfiguration.$current.withValue(
            ExhaustTraitConfiguration(budget: nil, regressions: [replaySeed])
        ) {
            await #execute(
                RegressionAsyncSequentialSpec.self,
                .commandLimit(8),
                .budget(.custom(coverage: 0, sampling: 1)),
                .suppress(.all)
            )
        }
        #expect(result != nil, "regression seed should reproduce the failure on its own")
    }
}

// MARK: - Specs

@StateMachine(.sequential)
private final class RegressionCounterSpec {
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

@StateMachine(.tasks)
private final class RegressionCounterCooperativeSpec {
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

@StateMachine(.threads)
private final class RegressionPreemptiveSpec {
    @SystemUnderTest var counter = RegressionRacyPreemptiveCounter()

    @Oracle
    func oracleMatches(other: RegressionRacyPreemptiveCounter) -> Bool {
        counter.value == other.value
    }

    @Command(weight: 3)
    func increment() throws {
        counter.increment()
    }

    @Command(weight: 2)
    func decrement() throws {
        guard counter.value > 0 else {
            throw skip()
        }
        counter.decrement()
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

/// Deliberately unsynchronized: concurrent read-modify-write loses updates, so the concurrent run diverges from the sequential replay and the `@Oracle` catches it. A deterministic bug would be invisible to the oracle, which compares two runs of the same spec.
private final class RegressionRacyPreemptiveCounter: @unchecked Sendable, CustomDebugStringConvertible {
    private var storedValue: Int = 0

    var value: Int {
        storedValue
    }

    var debugDescription: String {
        "RegressionRacyPreemptiveCounter(value: \(storedValue))"
    }

    func increment() {
        let current = storedValue
        Thread.sleep(forTimeInterval: 0.0001)
        storedValue = current + 1
    }

    func decrement() {
        let current = storedValue
        Thread.sleep(forTimeInterval: 0.0001)
        storedValue = current - 1
    }
}

@StateMachine(.sequential)
private final class RegressionAsyncSequentialSpec {
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
