import Testing
@testable import ExhaustCore

@Suite("LegBudget")
struct LegBudgetTests {
    @Test("Fresh budget is not exhausted")
    func freshBudget() {
        let budget = ReductionScheduler.LegBudget(hardCap: 10)
        #expect(budget.isExhausted == false)
        #expect(budget.used == 0)
    }

    @Test("Exhausts on hard cap")
    func hardCap() {
        var budget = ReductionScheduler.LegBudget(hardCap: 3)
        budget.recordMaterialization()
        budget.recordMaterialization()
        #expect(budget.isExhausted == false)
        budget.recordMaterialization()
        #expect(budget.isExhausted)
        #expect(budget.used == 3)
    }

    @Test("Productive leg can spend up to hard cap")
    func productiveLegUsesFullCap() {
        var budget = ReductionScheduler.LegBudget(hardCap: 5)
        for _ in 0 ..< 4 {
            budget.recordMaterialization()
        }
        #expect(budget.isExhausted == false)
        budget.recordMaterialization()
        #expect(budget.isExhausted)
        #expect(budget.used == 5)
    }
}
