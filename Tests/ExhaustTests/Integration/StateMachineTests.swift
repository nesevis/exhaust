import Testing
import Exhaust
import ExhaustCore

// MARK: - Test SUT: Simple counter with a known bug

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

// MARK: - State Machine Spec

@StateMachine
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

// MARK: - Passing spec: simple stack

@StateMachine
struct StackSpec {
    @Model var expected: [Int] = []
    @SUT var stack: [Int] = []

    @Invariant
    func contentsMatch() -> Bool {
        stack == expected
    }

    @Command(weight: 3, Gen.int(in: 0...9))
    mutating func push(value: Int) throws {
        expected.append(value)
        stack.append(value)
    }

    @Command(weight: 2)
    mutating func pop() throws {
        guard !expected.isEmpty else { throw skip() }
        let modelValue = expected.removeLast()
        let sutValue = stack.removeLast()
        try check(modelValue == sutValue, "pop values should match")
    }

    @Command(weight: 1)
    mutating func count() throws {
        try check(expected.count == stack.count, "counts should match")
    }
}

// MARK: - Tests

@Suite("State machine integration tests")
struct StateMachineIntegrationTests {
    @Test("Detects model/SUT divergence in buggy counter")
    func detectsBuggyCounter() throws {
        let result = try #require(
            #stateMachine(BuggyCounterSpec.self, .sequenceLength(3...10), .suppressIssueReporting)
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

    @Test("Passing spec produces no counterexample")
    func passingStack() {
        let result = #stateMachine(StackSpec.self, .sequenceLength(5...15), .maxIterations(50), .suppressIssueReporting)
        #expect(result == nil, "Stack spec should pass — model and SUT are identical")
    }

    @Test("Trace steps have correct structure")
    func traceSteps() throws {
        let result = try #require(
            #stateMachine(BuggyCounterSpec.self, .sequenceLength(3...10), .suppressIssueReporting)
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
