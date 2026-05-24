import ExhaustTestSupport
import Testing
@testable import Exhaust

@Suite("estimateCommandLimit", .serialized, .tags(.contract))
struct EstimateCommandLimitTests {
    @Test("Parameter-free 2-command pick produces ceiling-capped result")
    func parameterFree2CommandPickProducesCeilingCappedResult() {
        let gen = Gen.pick(choices: [
            (weight: 1, generator: Gen.just("a").map { $0 as Any }),
            (weight: 1, generator: Gen.just("b").map { $0 as Any }),
        ])
        let limit = estimateCommandLimit(commandGen: gen, coverageBudget: 200)
        #expect(limit <= 100, "Should be capped at 100 for sync runner")
        #expect(limit >= 6, "Should be at least the exploration floor (branchCount * 3)")
    }

    @Test("Non-pick generator falls back to 10")
    func nonPickGeneratorFallsBackTo10() {
        let gen = Gen.just("single value").map { $0 as Any }
        let limit = estimateCommandLimit(commandGen: gen, coverageBudget: 200)
        #expect(limit == 10)
    }

    @Test("Many commands produce higher exploration floor")
    func manyCommandsProduceHigherExplorationFloor() {
        let choices: [(weight: Int, generator: Generator<Any>)] = (0 ..< 10).map { index in
            (weight: 1, generator: Gen.just("\(index)").map { $0 as Any })
        }
        let gen = Gen.pick(choices: choices)
        let limit = estimateCommandLimit(commandGen: gen, coverageBudget: 200)
        #expect(limit >= 30, "Exploration floor should be at least branchCount * 3 = 30")
    }

    @Test("Zero coverage budget produces exploration floor")
    func zeroCoverageBudgetProducesExplorationFloor() {
        let gen = Gen.pick(choices: [
            (weight: 1, generator: Gen.just("a").map { $0 as Any }),
            (weight: 1, generator: Gen.just("b").map { $0 as Any }),
        ])
        let limit = estimateCommandLimit(commandGen: gen, coverageBudget: 0)
        #expect(limit >= 6, "Should still produce exploration floor even with zero budget")
    }
}
