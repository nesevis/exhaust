@testable import Exhaust
import Testing

@Suite("Sequential oracle for invariant-only specs")
struct SequentialOracleTests {
    @Test("Invariant-only spec shows expected SUT from sequential replay")
    func oraclePopulatesSUT() async throws {
        let result = try #require(
            await __runContractConcurrent(
                InvariantOnlyCounterSpec.self,
                settings: [
                    .commandLimit(4),
                    .budget(.custom(coverage: 0, sampling: 200)),
                    .suppress(.issueReporting)
                ]
            )
        )
        #expect(result.systemUnderTest != nil, "Sequential oracle should populate SUT for invariant-only specs")
    }

    @Test("Model-based spec also populates oracle SUT")
    func modelBasedSpecAlsoHasOracle() async throws {
        let result = try #require(
            await __runContractConcurrent(
                ModelBasedCounterSpec.self,
                settings: [.commandLimit(4), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
            )
        )
        #expect(result.systemUnderTest != nil, "Sequential oracle should populate SUT for all specs")
    }
}

// MARK: - Invariant-only spec (no @Model)

@Contract
final class InvariantOnlyCounterSpec {
    @SystemUnderTest
    var counter: RacyInvariantCounter = .init()

    @Invariant
    func neverDecreases() -> Bool {
        counter.value >= counter.previousValue
    }

    @Command(weight: 1)
    func increment() async throws {
        await counter.increment()
    }
}

// MARK: - Model-based spec (has @Model)

@Contract
final class ModelBasedCounterSpec {
    @Model
    var expected: Int = 0
    @SystemUnderTest
    var counter: RacyInvariantCounter = .init()

    @Invariant
    func matchesModel() -> Bool {
        counter.value == expected
    }

    @Command(weight: 1)
    func increment() async throws {
        expected += 1
        await counter.increment()
    }
}

// MARK: - SUT

/// Deliberately unsynchronized — @unchecked Sendable is required because the cooperative scheduler accesses the instance from multiple Tasks via SendableBox.
final class RacyInvariantCounter: @unchecked Sendable, CustomDebugStringConvertible {
    private var _value: Int = 0
    private var _previousValue: Int = 0

    var value: Int { _value }
    var previousValue: Int { _previousValue }

    var debugDescription: String {
        "RacyInvariantCounter(value: \(_value), previousValue: \(_previousValue))"
    }

    func increment() async {
        _previousValue = _value
        let current = _value
        await Task.yield()
        _value = current + 1
    }
}
