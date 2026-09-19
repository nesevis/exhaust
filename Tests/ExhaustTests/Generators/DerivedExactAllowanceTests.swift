import Exhaust
import ExhaustCore
import Testing
@testable import ExhaustGenerators

@Suite("Derived exact allowances")
struct DerivedExactAllowanceTests {
    @Test("Splitting preserves exact allowances, reserves minima and distributes the remainder")
    func exactSplit() {
        let inputs = #gen(.int(in: 1 ... 256).array(length: 0 ... 32), .int(in: 0 ... 8192))
        #exhaust(inputs, .budget(.extensive)) { minima, allowance in
            let plan = try GeneratorDerivationPlan(for: WideProduct.self, overrides: [:])
            let budget = GeneratorNodeBudget(plan: plan)
            let result = budget.split(allowance, minima: minima)
            if minima.reduce(0, +) > allowance {
                #expect(result == nil)
            } else {
                let shares = try #require(result)
                #expect(shares.count == minima.count)
                #expect(zip(shares, minima).allSatisfy { $0 >= $1 })
                if minima.isEmpty == false {
                    #expect(shares.reduce(0, +) == allowance)
                    let surplus = zip(shares, minima).map { $0 - $1 }
                    #expect(zip(surplus, surplus.dropFirst()).allSatisfy { $0 >= $1 })
                    let largest = try #require(surplus.max())
                    let smallest = try #require(surplus.min())
                    #expect(largest - smallest <= 1)
                }
            }
        }
    }

    @Test("Every feasible container count receives at least its entry minimum", arguments: [33, 34, 66, 67, 201])
    func containerSplitFeasibility(availableNodes: Int) throws {
        let plan = try GeneratorDerivationPlan(for: WideProduct.self, overrides: [:])
        let budget = GeneratorNodeBudget(plan: plan)
        let minima = [33]
        let minimum = try #require(sumNodes(minima))
        for elementCount in 1 ... availableNodes / minimum {
            let share = availableNodes / elementCount
            let allowances = try #require(budget.split(share, minima: minima))
            #expect(allowances == [share])
        }
    }

    @Test("A root rejects an insufficient allowance and constructs at its exact minimum", arguments: [32, 33, 35, 63])
    func rootMinimum(maximumNodes: Int) throws {
        for depth in [RootDepth.pinned(0), .drawn(ceiling: 0, scaling: .linear)] {
            let plan = try GeneratorDerivationPlan(for: WideProduct.self, overrides: [:])
            let builder = BudgetedGeneratorDerivation(plan: plan)
            if maximumNodes < 33 {
                #expect(throws: GeneratorDerivationError.insufficientNodes(type: "WideProduct", minimum: 33, requested: maximumNodes)) {
                    try builder.root(for: WideProduct.self, depth: depth, maximumNodes: maximumNodes)
                }
            } else {
                let generator = try builder.root(for: WideProduct.self, depth: depth, maximumNodes: maximumNodes)
                var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 42, maxRuns: 1, sizeOverride: 100)
                let (value, _) = try #require(try interpreter.next())
                #expect(value.nodes == 33)
            }
        }
    }

    @Test("A nested child requires its own nodes plus the enclosing product", arguments: [33, 34, 35])
    func nestedChildMinimum(maximumNodes: Int) throws {
        let plan = try GeneratorDerivationPlan(for: NestedWide.self, overrides: [:])
        let builder = BudgetedGeneratorDerivation(plan: plan)
        if maximumNodes < 34 {
            #expect(throws: GeneratorDerivationError.insufficientNodes(type: "NestedWide", minimum: 34, requested: maximumNodes)) {
                try builder.root(for: NestedWide.self, depth: .pinned(1), maximumNodes: maximumNodes)
            }
        } else {
            let generator = try builder.root(for: NestedWide.self, depth: .pinned(1), maximumNodes: maximumNodes)
            var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 42, maxRuns: 1, sizeOverride: 100)
            let (value, _) = try #require(try interpreter.next())
            #expect(value.nodes == 34)
        }
    }

    @Test("A container constructs when an entry's exact minimum fits")
    func containerEntryMinimum() throws {
        let generator = WideArray.gen(maximumDepth: 1, maximumNodes: 35)
        let samples = try #example(generator, count: 10)
        #expect(samples.allSatisfy { $0.nodes <= 35 })
        let entry = try #example(WideProduct.gen(depth: 0), seed: 42)
        let target = WideArray(entries: [entry])
        let reflected = try #require(try Interpreters.reflect(generator.gen, with: target))
        let replayed = try #require(try Interpreters.replay(generator.gen, using: reflected))
        #expect(replayed == target)
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
        33
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
