//
//  StructuralIsolatorTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

@Suite("StructuralIsolator")
struct StructuralIsolatorTests {
    @Test("Independent positions are zeroed when property still fails")
    func independentPositionsZeroed() throws {
        let gen = makeBindPlusIndependentGenerator()
        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (value, tree) = try #require(try iterator.next())
        try #require(value.1 > 0, "Need non-zero independent value")

        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)

        let result = StructuralIsolator.project(
            gen: gen,
            sequence: sequence,
            tree: tree,
            bindIndex: bindIndex,
            property: { _ in false },
            isInstrumented: false
        )

        #expect(result != nil)
        #expect(result?.output.1 == 0)
    }

    @Test("Monolithic bind generator — Phase 0 is a no-op")
    func monolithicBindNoOp() {
        // Everything inside bind span. No independent positions.
        let tree = ChoiceTree.bind(
            inner: .choice(.unsigned(5, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            bound: .group([
                .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
                .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            ])
        )

        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)

        // Dummy generator — isolate returns nil before materialization.
        let result = StructuralIsolator.project(
            gen: Gen.just(0 as UInt64),
            sequence: sequence,
            tree: tree,
            bindIndex: bindIndex,
            property: { _ in false },
            isInstrumented: false
        )

        #expect(result == nil)
    }

    @Test("Verification failure — fallback to original when zeroing causes property to pass")
    func verificationFailureFallback() throws {
        let gen = makeBindPlusIndependentGenerator()
        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (value, tree) = try #require(try iterator.next())
        try #require(value.1 > 0, "Need non-zero independent value")

        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)

        // Property passes when the independent value is 0.
        // Zeroing it makes the property pass → isolation returns nil.
        let result = StructuralIsolator.project(
            gen: gen,
            sequence: sequence,
            tree: tree,
            bindIndex: bindIndex,
            property: { output in output.1 == 0 },
            isInstrumented: false
        )

        #expect(result == nil)
    }

    @Test("No structural positions — all positions independent")
    func allPositionsIndependent() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64(0) ... 100),
            Gen.choose(in: UInt64(0) ... 100)
        )
        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (_, tree) = try #require(try iterator.next())

        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)

        let result = StructuralIsolator.project(
            gen: gen,
            sequence: sequence,
            tree: tree,
            bindIndex: bindIndex,
            property: { _ in false },
            isInstrumented: false
        )

        #expect(result != nil)
        #expect(result!.output.0 == 0)
        #expect(result!.output.1 == 0)
    }

    @Test("Branch at top level — branch group is connected")
    func branchGroupConnected() {
        // Pick-site group with selected branch containing a value.
        let branchA = ChoiceTree.branch(
            siteID: 0, weight: 1, id: 0, branchIDs: [0, 1],
            choice: .choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        )
        let branchB = ChoiceTree.branch(
            siteID: 0, weight: 1, id: 1, branchIDs: [0, 1],
            choice: .choice(.unsigned(20, .uint64), .init(validRange: 0 ... 200, isRangeExplicit: true))
        )
        let tree = ChoiceTree.group([branchA, .selected(branchB)])

        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)

        // All positions are inside the branch group — no independent positions.
        // Dummy generator — isolate returns nil before materialization.
        let result = StructuralIsolator.project(
            gen: Gen.just(0 as UInt64),
            sequence: sequence,
            tree: tree,
            bindIndex: bindIndex,
            property: { _ in false },
            isInstrumented: false
        )

        #expect(result == nil)
    }
}

// MARK: - Test Helpers

/// Builds a generator that produces `.group([.bind(inner, bound), .choice])` trees.
///
/// The bind maps a UInt64 inner (0...10) to a UInt64 bound (0...100), and the independent choice is in 0...100. Output is `(UInt64, UInt64)` where `.1` is the independent value.
private func makeBindPlusIndependentGenerator() -> ReflectiveGenerator<(UInt64, UInt64)> {
    let bindGen: ReflectiveGenerator<UInt64> = Gen.choose(in: UInt64(0) ... 10)._bound(
        forward: { (_: UInt64) in
            Gen.choose(in: UInt64(0) ... 100)
        },
        backward: { (output: UInt64) in
            output
        }
    )
    return Gen.zip(bindGen, Gen.choose(in: UInt64(0) ... 100))
}
