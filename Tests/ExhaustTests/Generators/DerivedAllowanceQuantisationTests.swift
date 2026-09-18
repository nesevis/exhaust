import Exhaust
import Testing
@testable import ExhaustGenerators

@Suite("Derived allowance quantisation")
struct DerivedAllowanceQuantisationTests {
    @Test("The grid never rounds an allowance below the minimum its recipient needs")
    func floorHolds() {
        #expect(quantisedAllowance(33, notBelow: 1) == 32)
        #expect(quantisedAllowance(33, notBelow: 33) == 33)
        #expect(quantisedAllowance(16, notBelow: 1) == 16)
        #expect(quantisedAllowance(201, notBelow: 1) == 200)
        #expect(quantisedAllowance(201, notBelow: 201) == 201)
    }

    @Test("A root whose minimum the grid would round below still constructs", arguments: [33, 35, 63])
    func rootMinimum(maximumNodes: Int) throws {
        for generator in [
            WideProduct.gen(maximumDepth: 0, maximumNodes: maximumNodes),
            WideProduct.gen(depth: 0, maximumNodes: maximumNodes),
        ] {
            let samples = try #example(generator, count: 10)
            #expect(samples.allSatisfy { $0.nodes <= maximumNodes })
        }
    }

    @Test("A nested child whose minimum the grid would round below still constructs")
    func nestedChildMinimum() throws {
        let samples = try #example(NestedWide.gen(maximumDepth: 1, maximumNodes: 35), count: 10)
        #expect(samples.allSatisfy { $0.nodes <= 35 })
    }

    @Test("A container entry whose minimum the grid would round below still constructs")
    func containerEntryMinimum() throws {
        let samples = try #example(WideArray.gen(maximumDepth: 1, maximumNodes: 35), count: 10)
        #expect(samples.allSatisfy { $0.nodes <= 35 })
    }
}

// MARK: - Fixtures

/// Costs 33 nodes at minimum: one for the product, one for each field. The grid rounds 33 down to 32, so a ceiling of 33 is only constructible when the floor holds.
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
