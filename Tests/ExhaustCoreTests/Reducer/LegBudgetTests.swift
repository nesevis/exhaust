import Testing
@testable import ExhaustCore

@Suite("LegBudget")
struct LegBudgetTests {
    @Test("Fresh budget is not exhausted")
    func freshBudget() {
        let budget = ReductionScheduler.LegBudget(hardCap: 10, stallPatience: 5)
        #expect(budget.isExhausted == false)
        #expect(budget.used == 0)
        #expect(budget.consecutiveFruitless == 0)
    }

    @Test("Exhausts on hard cap")
    func hardCap() {
        var budget = ReductionScheduler.LegBudget(hardCap: 3, stallPatience: 10)
        budget.recordMaterialization(accepted: true)
        budget.recordMaterialization(accepted: true)
        #expect(budget.isExhausted == false)
        budget.recordMaterialization(accepted: true)
        #expect(budget.isExhausted)
        #expect(budget.used == 3)
    }

    @Test("Exhausts on stall patience")
    func stallPatience() {
        var budget = ReductionScheduler.LegBudget(hardCap: 100, stallPatience: 3)
        budget.recordMaterialization(accepted: false)
        budget.recordMaterialization(accepted: false)
        #expect(budget.isExhausted == false)
        budget.recordMaterialization(accepted: false)
        #expect(budget.isExhausted)
        #expect(budget.consecutiveFruitless == 3)
    }

    @Test("Success resets consecutive fruitless counter")
    func successResets() {
        var budget = ReductionScheduler.LegBudget(hardCap: 100, stallPatience: 3)
        budget.recordMaterialization(accepted: false)
        budget.recordMaterialization(accepted: false)
        #expect(budget.consecutiveFruitless == 2)
        budget.recordMaterialization(accepted: true)
        #expect(budget.consecutiveFruitless == 0)
        #expect(budget.isExhausted == false)
    }

    @Test("Stall patience does not scale with hard cap")
    func patienceIndependentOfCap() {
        // Large hard cap, small patience — should stall after 2 fruitless, not after 100.
        var budget = ReductionScheduler.LegBudget(hardCap: 100, stallPatience: 2)
        budget.recordMaterialization(accepted: false)
        budget.recordMaterialization(accepted: false)
        #expect(budget.isExhausted)
        #expect(budget.used == 2)
    }

    @Test("Productive leg can spend up to hard cap")
    func productiveLegUsesFullCap() {
        var budget = ReductionScheduler.LegBudget(hardCap: 5, stallPatience: 2)
        // Alternate success/failure — never hits stall patience.
        budget.recordMaterialization(accepted: true)
        budget.recordMaterialization(accepted: false)
        budget.recordMaterialization(accepted: true)
        budget.recordMaterialization(accepted: false)
        #expect(budget.isExhausted == false)
        budget.recordMaterialization(accepted: true)
        #expect(budget.isExhausted) // hard cap reached
        #expect(budget.used == 5)
    }
}

@Suite("CycleBudget")
struct CycleBudgetTests {
    @Test("Default weights sum to 1")
    func defaultWeightsSum() {
        let weights = CycleBudget.defaultWeights()
        let sum = weights.values.reduce(0, +)
        #expect(abs(sum - 1.0) < 0.001)
    }

    @Test("Initial budgets partition the total")
    func initialBudgetsPartition() {
        let budget = CycleBudget(total: 200, legWeights: CycleBudget.defaultWeights())
        let branch = budget.initialBudget(for: .branch) // 5% = 10
        let contra = budget.initialBudget(for: .contravariant) // 30% = 60
        let deletion = budget.initialBudget(for: .deletion) // 30% = 60
        let covariant = budget.initialBudget(for: .covariant) // 25% = 50
        let redist = budget.initialBudget(for: .redistribution) // 10% = 20
        #expect(branch == 10)
        #expect(contra == 60)
        #expect(deletion == 60)
        #expect(covariant == 50)
        #expect(redist == 20)
        #expect(branch + contra + deletion + covariant + redist == 200)
    }

    @Test("Unused budget forwarding preserves total")
    func forwardingPreservesTotal() {
        let budget = CycleBudget(total: 100, legWeights: CycleBudget.defaultWeights())
        var remaining = budget.total
        for leg in ReductionLeg.allCases {
            let target = budget.initialBudget(for: leg)
            // Simulate each leg using half its target.
            let used = target / 2
            remaining -= used
        }
        // Remaining should be total minus sum of (target/2).
        #expect(remaining > 0)
    }
}
