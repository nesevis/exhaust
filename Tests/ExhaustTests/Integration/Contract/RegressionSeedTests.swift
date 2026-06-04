import Exhaust
import Testing

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
}

// MARK: - Specs

@Contract(.sequential)
private final class RegressionCounterContract {
    @Model var expected: Int = 0
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
        guard expected > 0 else { throw skip() }
        expected -= 1
        counter.decrement()
    }
}

@Contract(.tasks)
private final class RegressionCounterCooperativeContract {
    @Model var expected: Int = 0
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
