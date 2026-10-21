import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Paired value oracle")
struct PairedValueOracleTests {
    @Test("Equal values are counted and differing values are rejected")
    func values() {
        let constant = Gen.just(1).erase()
        let same = checkPairedValues(constant, constant, maxRuns: 3, check: anyEquals)
        #expect(same.matches)
        #expect(same.evaluated == 3)
        #expect(checkPairedValues(constant, Gen.just(2).erase(), check: anyEquals).matches == false)
    }

    @Test("One-sided exhaustion is rejected in either order", arguments: [false, true])
    func unequalLengths(reverse: Bool) {
        let constant = Gen.just(1).erase()
        let unique = ReflectiveGenerator(Gen.exact(1), isReflective: true).unique().gen.erase()
        let result = checkPairedValues(reverse ? unique : constant, reverse ? constant : unique, check: anyEquals)
        #expect(result.matches == false)
        #expect(result.evaluated == 1)
    }

    @Test("Matching rejection remains distinguishable from evaluated values")
    func matchingErrors() throws {
        let failing = try failingGenerator(.first)
        let result = checkPairedValues(failing, failing, check: anyEquals)
        #expect(result.matches)
        #expect(result.evaluated == 0)
    }

    @Test("Different errors and one-sided errors are rejected", arguments: [false, true])
    func mismatchingErrors(reverse: Bool) throws {
        let failing = try failingGenerator(.first)
        let constant = Gen.just(1).erase()
        #expect(checkPairedValues(reverse ? failing : constant, reverse ? constant : failing, check: anyEquals).matches == false)
        #expect(try checkPairedValues(failing, failingGenerator(.second), check: anyEquals).matches == false)
    }

    @Test("Empty sampling budgets report zero evaluations")
    func emptyBudget() {
        let constant = Gen.just(1).erase()
        let result = checkPairedValues(constant, constant, maxRuns: 0, check: anyEquals)
        #expect(result.matches)
        #expect(result.evaluated == 0)
    }

    @Test("The core property harness rejects zero evaluations")
    func emptyPropertyRun() {
        withKnownIssue("A property must evaluate at least one value") {
            try exhaustCheck(Gen.just(1), maxIterations: 0) { _ in true }
        }
    }
}

private enum OracleError: Error {
    case first
    case second
}

private func failingGenerator(_ error: OracleError) throws -> AnyGenerator {
    try (Gen.choose(in: 0 ... 1) as Generator<Int>).map { _ throws -> Int in
        throw error
    }.erase()
}
