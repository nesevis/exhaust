import ExhaustTestSupport
import Testing
@testable import Exhaust

@Suite("estimateCommandLimit", .serialized, .tags(.contract))
struct EstimateCommandLimitTests {
    @Test
    func `Parameter-free 2-command pick produces ceiling-capped result`() {
        let gen = Gen.pick(choices: [
            (weight: 1, generator: Gen.just("a").map { $0 as Any }),
            (weight: 1, generator: Gen.just("b").map { $0 as Any }),
        ])
        let limit = estimateCommandLimit(commandGen: gen, coverageBudget: 200)
        #expect(limit <= 100, "Should be capped at 100 for sync runner")
        #expect(limit >= 6, "Should be at least the exploration floor (branchCount * 3)")
    }

    @Test
    func `Non-pick generator falls back to 10`() {
        let gen = Gen.just("single value").map { $0 as Any }
        let limit = estimateCommandLimit(commandGen: gen, coverageBudget: 200)
        #expect(limit == 10)
    }

    @Test
    func `Many commands produce higher exploration floor`() {
        let choices: [(weight: Int, generator: Generator<Any>)] = (0 ..< 10).map { index in
            (weight: 1, generator: Gen.just("\(index)").map { $0 as Any })
        }
        let gen = Gen.pick(choices: choices)
        let limit = estimateCommandLimit(commandGen: gen, coverageBudget: 200)
        #expect(limit >= 30, "Exploration floor should be at least branchCount * 3 = 30")
    }

    @Test
    func `Zero coverage budget produces exploration floor`() {
        let gen = Gen.pick(choices: [
            (weight: 1, generator: Gen.just("a").map { $0 as Any }),
            (weight: 1, generator: Gen.just("b").map { $0 as Any }),
        ])
        let limit = estimateCommandLimit(commandGen: gen, coverageBudget: 0)
        #expect(limit >= 6, "Should still produce exploration floor even with zero budget")
    }
}
