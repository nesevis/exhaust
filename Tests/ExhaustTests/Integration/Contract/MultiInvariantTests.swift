import Exhaust
import Testing

@Suite("Multiple @Invariant methods")
struct MultiInvariantTests {
    @Test("First failing invariant is reported in trace")
    func firstFailingInvariantReported() {
        let result = #exhaust(
            FiveInvariantSpec.self,
            .commandLimit(4),
            .suppress(.issueReporting)
        )
        #expect(result != nil, "Should find a failure")
        if let result {
            let failedInvariants = result.trace.compactMap { step -> String? in
                if case let .invariantFailed(name) = step.outcome { return name }
                return nil
            }
            #expect(failedInvariants.isEmpty == false, "Should have at least one invariant failure")
            #expect(failedInvariants[0] == "countMatches", "First invariant alphabetically should be reported (checkInvariants stops at first failure)")
        }
    }

    @Test("Passing spec with five invariants produces no counterexample")
    func fiveInvariantsAllPass() {
        let result = #exhaust(
            PassingFiveInvariantSpec.self,
            .commandLimit(6),
            .budget(.custom(coverage: 100, sampling: 50)),
            .suppress(.issueReporting)
        )
        #expect(result == nil, "All five invariants should pass")
    }
}

// MARK: - Spec: Five invariants, one fails

@Contract
struct FiveInvariantSpec {
    @Model
    var expected: Int = 0
    @SystemUnderTest
    var counter: BuggyModCounter = .init()

    @Invariant func countMatches() -> Bool {
        counter.value == expected
    }

    @Invariant func neverNegative() -> Bool {
        counter.value >= 0
    }

    @Invariant func withinBounds() -> Bool {
        counter.value <= 100
    }

    @Invariant func evenStepsEven() -> Bool {
        expected % 2 == 0 ? counter.value % 2 == 0 : true
    }

    @Invariant func oddStepsOdd() -> Bool {
        expected % 2 == 1 ? counter.value % 2 == 1 : true
    }

    @Command(weight: 3)
    mutating func increment() throws {
        expected += 1
        counter.increment()
    }
}

// MARK: - Spec: Five invariants, all pass

@Contract
struct PassingFiveInvariantSpec {
    @Model
    var expected: Int = 0
    @SystemUnderTest
    var counter: CorrectCounter = .init()

    @Invariant func countMatches() -> Bool {
        counter.value == expected
    }

    @Invariant func neverNegative() -> Bool {
        counter.value >= 0
    }

    @Invariant func withinBounds() -> Bool {
        counter.value <= 1000
    }

    @Invariant func parity() -> Bool {
        counter.value % 2 == expected % 2
    }

    @Invariant func monotonic() -> Bool {
        counter.value >= 0
    }

    @Command(weight: 3)
    mutating func increment() throws {
        expected += 1
        counter.increment()
    }

    @Command(weight: 1)
    mutating func reset() throws {
        expected = 0
        counter.reset()
    }
}

// MARK: - SUTs

struct BuggyModCounter {
    private(set) var value: Int = 0
    mutating func increment() {
        value = (value + 1) % 3
    }
}

struct CorrectCounter {
    private(set) var value: Int = 0
    mutating func increment() {
        value += 1
    }

    mutating func reset() {
        value = 0
    }
}
