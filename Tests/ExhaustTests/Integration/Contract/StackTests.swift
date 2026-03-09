import Testing
import Exhaust
import ExhaustCore

// MARK: - State Machine Spec: Simple stack

@Contract
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

@Suite("Stack state machine tests")
struct StackTests {
    @Test("Passing spec produces no counterexample")
    func passingStack() {
        let result = #exhaust(StackSpec.self, commandLimit: 15, .maxIterations(50), .suppressIssueReporting)
        #expect(result == nil, "Stack spec should pass — model and SUT are identical")
    }
}
