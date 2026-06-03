import Exhaust
import ExhaustTestSupport
import Testing

// MARK: - Tests

@Suite("Buggy counter state machine tests", .serialized, .tags(.contract))
struct BuggyCounterTests {
    @Test("Detects model/SUT divergence in buggy counter")
    func detectsModelSUTDivergenceInBuggyCounter() throws {
        let result = try #require(
            #execute(
                BuggyCounterSpec.self,
                .commandLimit(10),
                .suppress(.issueReporting)
            )
        )
        // The trace should end with a failing step
        #expect(result.trace.last.map { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        } == true)

        // The SUT should be a BuggyCounter with capacity 3
        #expect(result.systemUnderTest?.capacity == 3)
    }

    @Test("Trace steps have correct structure")
    func traceStepsHaveCorrectStructure() throws {
        let result = try #require(
            #execute(
                BuggyCounterSpec.self,
                .commandLimit(10),
                .suppress(.issueReporting)
            )
        )

        // Every step should have a 1-based index
        for (offset, step) in result.trace.enumerated() {
            #expect(step.index == offset + 1)
        }

        // At least the last step should not be .ok (it's the failing step)
        if let lastStep = result.trace.last {
            if case .ok = lastStep.outcome {
                Issue.record("Last trace step should be a failure, not .ok")
            }
        }

        // Trace descriptions should be non-empty
        for step in result.trace {
            #expect(!step.description.isEmpty)
        }
    }

    @Test("Sequential contract failure carries replay seed")
    func sequentialContractFailureCarriesReplaySeed() throws {
        let result = try #require(
            #execute(
                BuggyCounterSpec.self,
                .commandLimit(10),
                .budget(.custom(coverage: 0, sampling: 200)),
                .suppress(.issueReporting)
            )
        )
        #expect(result.replaySeed != nil, "Sampling failure should carry a replay seed")
        #expect(result.seed != nil, "Sampling failure should carry a PRNG seed")
    }

    @Test("Sequential contract SCA coverage failure carries U-prefixed replay seed")
    func sequentialContractSCACoverageFailureCarriesUPrefixedReplaySeed() throws {
        let result = try #require(
            #execute(
                BuggyCounterSpec.self,
                .commandLimit(4),
                .suppress(.issueReporting)
            )
        )
        if result.discoveryMethod == .coverage {
            let replaySeed = try #require(result.replaySeed)
            #expect(replaySeed.hasPrefix("U"), "SCA coverage replay seed should have U prefix")
        }
    }
}

@Suite("SCA reduction coverage", .serialized, .tags(.contract))
struct SCAReductionCoverageTests {
    @Test("SCA coverage exercises the reduction path")
    func scaCoverageExercisesReductionPath() throws {
        let result = try #require(
            #execute(
                PairwiseBugSpec.self,
                .commandLimit(3),
                .budget(.custom(coverage: 200, sampling: 0)),
                .suppress(.issueReporting),
                .log(.debug)
            )
        )
        #expect(result.discoveryMethod == .coverage)
        #expect(result.trace.isEmpty == false)
    }
}

// MARK: - Contract

@Contract
struct BuggyCounterSpec {
    @Model var expectedValue: Int = 0
    @SystemUnderTest var counter = BuggyCounter(capacity: 3)

    @Invariant
    func valueMatches() -> Bool {
        counter.value == expectedValue
    }

    @Command(weight: 3)
    mutating func increment() throws {
        // Model uses capacity 5, SUT uses capacity 3 — diverges after 3 increments
        expectedValue = (expectedValue + 1) % 5
        counter.increment()
    }

    @Command(weight: 1)
    mutating func reset() throws {
        expectedValue = 0
        counter.reset()
    }
}

// MARK: - Types

/// A counter that wraps to zero after reaching a threshold. The bug: it wraps at 3 instead of the stated capacity of 5.
struct BuggyCounter {
    private(set) var value: Int = 0
    let capacity: Int

    mutating func increment() {
        value = (value + 1) % capacity
    }

    mutating func reset() {
        value = 0
    }
}

// MARK: - Pairwise Bug Contract

/// A contract where any sequence containing both `setA` and `setB` triggers the invariant failure. Pairwise SCA at t=2 is guaranteed to produce such a row.
@Contract
struct PairwiseBugSpec {
    @Model var modelState: Int = 0
    @SystemUnderTest var sut = PairwiseBugSUT()

    @Invariant
    func notBothSet() -> Bool {
        sut.flagA == false || sut.flagB == false
    }

    @Command
    mutating func setA() throws {
        sut.flagA = true
    }

    @Command
    mutating func setB() throws {
        sut.flagB = true
    }

    @Command
    mutating func noop() throws {}
}

struct PairwiseBugSUT {
    var flagA: Bool = false
    var flagB: Bool = false
}
