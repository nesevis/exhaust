//
//  CoverageBudgetTests.swift
//  ExhaustTests
//

import Testing
@testable import Exhaust

@Suite("Coverage Budget")
struct CoverageBudgetTests {
    @Test("coverageBudget setting is parsed")
    func coverageBudgetSettingIsParsed() {
        // This should compile and run without issues
        let gen = #gen(.bool(), .bool(), .int(in: 0 ... 2))
        #exhaust(gen, .budget(.custom(coverage: 50, sampling: 50))) { _, _, _ in
            true
        }
    }

    @Test("Budget * UInt64 scales both components")
    func budgetUInt64ScalesBothComponents() {
        let budget = ExhaustBudget.standard
        let scaled = budget * 3
        #expect(scaled.coverageBudget == budget.coverageBudget * 3)
        #expect(scaled.samplingBudget == budget.samplingBudget * 3)
    }

    @Test("UInt64 * Budget is commutative")
    func uInt64BudgetIsCommutative() {
        let budget = ExhaustBudget.standard
        let lhs = budget * 2
        let rhs = 2 * budget
        #expect(lhs.coverageBudget == rhs.coverageBudget)
        #expect(lhs.samplingBudget == rhs.samplingBudget)
    }

    @Test("Budget / UInt64 divides both components")
    func budgetUInt64DividesBothComponents() {
        let budget = ExhaustBudget.custom(coverage: 100, sampling: 200)
        let divided = budget / 2
        #expect(divided.coverageBudget == 50)
        #expect(divided.samplingBudget == 100)
    }

    @Test("All discovery methods have descriptions")
    func allDiscoveryMethodsHaveDescriptions() {
        #expect(ContractDiscoveryMethod.coverage.description == "coverage")
        #expect(ContractDiscoveryMethod.randomSampling.description == "random sampling")
        #expect(ContractDiscoveryMethod.replay.description == "replay")
    }
}
