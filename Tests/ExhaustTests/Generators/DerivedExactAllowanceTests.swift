import Exhaust
import Testing
@testable import ExhaustGenerators

@Suite("Derived exact allowances")
struct DerivedExactAllowanceTests {
    @Test("Splitting preserves exact allowances, reserves minima and distributes the remainder")
    func exactSplit() throws {
        let plan = try GeneratorDerivationPlan(for: WideProduct.self, overrides: [:])
        let budget = GeneratorNodeBudget(plan: plan)
        #expect(budget.split(33, minima: [1]) == [33])
        #expect(budget.split(33, minima: [33]) == [33])
        #expect(budget.split(16, minima: [1]) == [16])
        #expect(budget.split(201, minima: [1]) == [201])
        #expect(budget.split(201, minima: [201]) == [201])
        #expect(budget.split(34, minima: [1, 2, 3]) == [11, 11, 12])
        #expect(budget.split(5, minima: [1, 2, 3]) == nil)
    }

    @Test("Every feasible container count receives at least its entry minimum", arguments: [33, 34, 66, 67, 201])
    func containerSplitFeasibility(availableNodes: Int) throws {
        let plan = try GeneratorDerivationPlan(for: WideProduct.self, overrides: [:])
        let budget = GeneratorNodeBudget(plan: plan)
        let minima = [33]
        let minimum = try #require(sumNodes(minima))
        for elementCount in 1 ... availableNodes / minimum {
            let share = availableNodes / elementCount
            #expect(share >= minimum)
            let allowances = try #require(budget.split(share, minima: minima))
            #expect(allowances == [share])
            #expect(allowances.reduce(0, +) * elementCount <= availableNodes)
        }
    }

    @Test("A root constructs at and above its exact minimum", arguments: [33, 35, 63])
    func rootMinimum(maximumNodes: Int) throws {
        for generator in [
            WideProduct.gen(maximumDepth: 0, maximumNodes: maximumNodes),
            WideProduct.gen(depth: 0, maximumNodes: maximumNodes),
        ] {
            let samples = try #example(generator, count: 10)
            #expect(samples.allSatisfy { $0.nodes <= maximumNodes })
        }
    }

    @Test("A nested child constructs when its exact minimum fits")
    func nestedChildMinimum() throws {
        let samples = try #example(NestedWide.gen(maximumDepth: 1, maximumNodes: 35), count: 10)
        #expect(samples.allSatisfy { $0.nodes <= 35 })
    }

    @Test("A container constructs when an entry's exact minimum fits")
    func containerEntryMinimum() throws {
        let samples = try #example(WideArray.gen(maximumDepth: 1, maximumNodes: 35), count: 10)
        #expect(samples.allSatisfy { $0.nodes <= 35 })
    }
}

// MARK: - Fixtures

/// Costs exactly 33 nodes: one for the product and one for each field. A ceiling of 33 leaves no spare allowance.
@Exhaustable
private struct WideProduct: Equatable {
    let field0: Int
    let field1: Int
    let field2: Int
    let field3: Int
    let field4: Int
    let field5: Int
    let field6: Int
    let field7: Int
    let field8: Int
    let field9: Int
    let field10: Int
    let field11: Int
    let field12: Int
    let field13: Int
    let field14: Int
    let field15: Int
    let field16: Int
    let field17: Int
    let field18: Int
    let field19: Int
    let field20: Int
    let field21: Int
    let field22: Int
    let field23: Int
    let field24: Int
    let field25: Int
    let field26: Int
    let field27: Int
    let field28: Int
    let field29: Int
    let field30: Int
    let field31: Int

    var nodes: Int {
        1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1
    }
}

@Exhaustable
private struct NestedWide: Equatable {
    let wide: WideProduct

    var nodes: Int {
        1 + wide.nodes
    }
}

@Exhaustable
private struct WideArray: Equatable {
    let entries: [WideProduct]

    var nodes: Int {
        1 + 1 + entries.reduce(0) { $0 + $1.nodes }
    }
}
