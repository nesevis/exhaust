import Testing
import Exhaust
import ExhaustCore

// MARK: - Tests

@Suite("Buggy counter state machine tests")
struct BuggyCounterTests {
    @Test("Detects model/SUT divergence in buggy counter")
    func detectsBuggyCounter() throws {
        let result = try #require(
            #exhaust(
                BuggyCounterSpec.self,
                commandLimit: 10,
                .suppressIssueReporting
            )
        )
        print()
        // The trace should end with a failing step
        #expect(result.trace.last.map { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        } == true)

        // The SUT should be a BuggyCounter with capacity 3
        #expect(result.sut.capacity == 3)
    }

    @Test("Trace steps have correct structure")
    func traceSteps() throws {
        let result = try #require(
            #exhaust(
                BuggyCounterSpec.self,
                commandLimit: 10,
                .suppressIssueReporting
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
}

// MARK: - Contract

@Contract
struct BuggyCounterSpec {
    @Model var expectedValue: Int = 0
    @SUT var counter = BuggyCounter(capacity: 3)

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
