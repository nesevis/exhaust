import Exhaust
import ExhaustTestSupport
import Testing

// MARK: - Tests

@Suite("Stack state machine tests", .serialized, .tags(.contract))
struct StackTests {
    @Test("Passing spec produces no counterexample")
    func passingSpecProducesNoCounterexample() {
        let result = #execute(
            StackSpec.self,
            .commandLimit(15),
            .budget(.custom(coverage: 500, sampling: 50)),
            .suppress(.issueReporting)
        )
        #expect(result == nil, "Stack spec should pass — model and SUT are identical")
    }
}

// MARK: - Contract

@Contract(.sequential)
final class StackSpec {
    @Model var expected: [Int] = []
    @SystemUnderTest var stack: [Int] = []

    @Invariant
    func contentsMatch() -> Bool {
        stack == expected
    }

    @Command(weight: 3, .int(in: 0 ... 9))
    func push(value: Int) throws {
        expected.append(value)
        stack.append(value)
    }

    @Command(weight: 2)
    func pop() throws {
        guard !expected.isEmpty else { throw skip() }
        let modelValue = expected.removeLast()
        let sutValue = stack.removeLast()
        try check(modelValue == sutValue, "pop values should match")
    }

    @Command(weight: 1)
    func count() throws {
        try check(expected.count == stack.count, "counts should match")
    }
}
