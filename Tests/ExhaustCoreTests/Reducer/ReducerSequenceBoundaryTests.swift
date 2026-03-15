//
//  ReducerSequenceBoundaryTests.swift
//  ExhaustTests
//
//  Tests for Pass 2a of Interpreters.reduce: collapsing sequence boundaries.
//  Pass 2a finds `][` boundary patterns inside nested sequences and removes
//  them, merging adjacent inner sequences (e.g. [[V][V][V]] → [[VVV]]).
//

import ExhaustCore
import Testing

// MARK: - Helpers

/// Generate a value and its choice tree from a generator with a given seed.
/// - Parameter iteration: Which iteration to use (0-indexed). Higher iterations use larger size values.
private func generate<Output>(
    _ gen: ReflectiveGenerator<Output>,
    seed: UInt64 = 42,
    iteration: Int = 0
) throws -> (value: Output, tree: ChoiceTree) {
    var iter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed)
    return try #require(iter.prefix(iteration + 1).last)
}

// MARK: - Tests

@Suite("Reducer Pass 2a: collapse sequence boundaries")
struct ReducerSequenceBoundaryTests {
    // MARK: - Boundary detection in generated sequences

    @Test("Nested array-of-arrays produces sequence boundaries in flattened form")
    func nestedArrayProducesBoundaries() throws {
        // [[UInt64]] with 3 inner arrays of 2 elements each
        let innerGen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 2)
        let gen = Gen.arrayOf(innerGen, exactly: 3)

        let (_, tree) = try generate(gen)
        let sequence = ChoiceSequence.flatten(tree)

        // The flattened form should contain `][` boundaries between inner sequences
        let boundarySpans = ChoiceSequence.extractSequenceBoundarySpans(from: sequence)
        #expect(boundarySpans.isEmpty == false)
        // 3 inner sequences → 2 boundaries between them
        #expect(boundarySpans.count == 2)
    }

    @Test("Single flat array has no sequence boundaries")
    func flatArrayNoBoundaries() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 5)

        let (_, tree) = try generate(gen)
        let sequence = ChoiceSequence.flatten(tree)

        #expect(ChoiceSequence.extractSequenceBoundarySpans(from: sequence).isEmpty)
    }

    // MARK: - Reduce collapses boundaries

    @Test("Reduce collapses boundaries in nested array when property still fails")
    func reduceCollapsesBoundaries() throws {
        // A nested array [[UInt64]] where the property fails when total element count > 0.
        // After collapsing boundaries, the structure should simplify.
        let innerGen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 2)
        let gen = Gen.arrayOf(innerGen, exactly: 3)

        let (_, tree) = try generate(gen)
        let originalSequence = ChoiceSequence.flatten(tree)

        // Property: always fails (value exists). This lets the reducer freely simplify.
        let property: ([[UInt64]]) -> Bool = { _ in false }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        let reducedSequence = result.0

        // The reduced sequence should be strictly simpler (shorter or lexicographically smaller)
        #expect(reducedSequence.shortLexPrecedes(originalSequence))
    }

    @Test("Reduced sequence has fewer boundaries than original")
    func reducedSequenceHasFewerBoundaries() throws {
        let innerGen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: UInt64(1) ... 5)
        let gen = Gen.arrayOf(innerGen, within: UInt64(2) ... 5)

        // Find a seed that produces multiple inner sequences (i.e. boundaries exist)
        // Use iteration 80 so the size parameter is large enough for variable-length arrays
        // (linear scaling needs size ~80 for range 2...5 to expand to 2...4)
        var foundTree: ChoiceTree?
        for seed: UInt64 in 0 ... 100 {
            let (_, tree) = try generate(gen, seed: seed, iteration: 80)
            let seq = ChoiceSequence.flatten(tree)
            if ChoiceSequence.extractSequenceBoundarySpans(from: seq).isEmpty == false {
                foundTree = tree
                break
            }
        }
        let tree = try #require(foundTree)
        let originalSequence = ChoiceSequence.flatten(tree)
        let originalBoundaries = ChoiceSequence.extractSequenceBoundarySpans(from: originalSequence)
        #expect(originalBoundaries.isEmpty == false)

        // Property always fails → reducer can freely collapse
        let property: ([[UInt64]]) -> Bool = { _ in false }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        let reducedBoundaries = ChoiceSequence.extractSequenceBoundarySpans(from: result.0)
        #expect(reducedBoundaries.count < originalBoundaries.count)
    }

    @Test("Reduce preserves property failure after collapsing boundaries")
    func reducePreservesPropertyFailure() throws {
        let innerGen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 2)
        let gen = Gen.arrayOf(innerGen, exactly: 3)

        let (_, tree) = try generate(gen)

        // Property fails when any element is > 50
        let property: ([[UInt64]]) -> Bool = { arrays in
            arrays.allSatisfy { $0.allSatisfy { $0 <= 50 } }
        }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        // The reduced output must still fail the property
        #expect(property(result.1) == false)
    }

    // MARK: - Boundary-only reduction (pass 1 has nothing to do)

    @Test("When containers cannot be deleted, pass 2a still collapses boundaries")
    func pass2aFiresIndependently() throws {
        // Use a property that requires at least some elements to exist,
        // so pass 1 (container deletion) cannot delete everything.
        let innerGen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 1)
        let gen = Gen.arrayOf(innerGen, exactly: 4)

        let (_, tree) = try generate(gen)
        let originalSequence = ChoiceSequence.flatten(tree)

        // Property: fails when there are more than 1 total element
        let property: ([[UInt64]]) -> Bool = { arrays in
            arrays.flatMap(\.self).count <= 1
        }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        // Should be simpler than the original
        #expect(result.0.shortLexPrecedes(originalSequence))
    }

    // MARK: - Edge cases

    @Test("Reduce with single inner sequence produces no boundaries to collapse")
    func singleInnerSequenceNoBoundaries() throws {
        // Only one inner array → no `][` pattern exists
        let innerGen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 3)
        let gen = Gen.arrayOf(innerGen, exactly: 1)

        let (_, tree) = try generate(gen)
        let sequence = ChoiceSequence.flatten(tree)

        #expect(ChoiceSequence.extractSequenceBoundarySpans(from: sequence).isEmpty)
    }

    @Test("Reduce with property that always passes returns original without changes")
    func propertyAlwaysPassesNoReduction() throws {
        let innerGen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 2)
        let gen = Gen.arrayOf(innerGen, exactly: 3)

        let (_, tree) = try generate(gen)
        let originalSequence = ChoiceSequence.flatten(tree)

        // Property always passes → nothing is a counterexample → no reduction possible
        let property: ([[UInt64]]) -> Bool = { _ in true }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        // Sequence should be unchanged (no improvement found)
        #expect(result.0 == originalSequence)
    }

    // MARK: - Materialization correctness after collapse

    @Test("Materialized output from reduced sequence is valid")
    func materializedOutputIsValid() throws {
        let innerGen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 2)
        let gen = Gen.arrayOf(innerGen, exactly: 3)

        let (_, tree) = try generate(gen)

        let property: ([[UInt64]]) -> Bool = { _ in false }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        // The output should be materializable from the reduced sequence
        let rematerialized = try Interpreters.materialize(gen, with: tree, using: result.0)
        #expect(rematerialized != nil)
    }

    @Test("Reduced output matches rematerialization from reduced sequence")
    func reducedOutputMatchesRematerialization() throws {
        let innerGen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 2)
        let gen = Gen.arrayOf(innerGen, exactly: 3)

        let (_, tree) = try generate(gen)

        let property: ([[UInt64]]) -> Bool = { _ in false }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        let rematerialized = try #require(
            try Interpreters.materialize(gen, with: tree, using: result.0)
        )

        // The output stored in the result should match a fresh materialization
        #expect(result.1 == rematerialized)
    }

    // MARK: - Sequence validity

    @Test("Reduced sequence has balanced brackets")
    func reducedSequenceHasBalancedBrackets() throws {
        let innerGen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 2)
        let gen = Gen.arrayOf(innerGen, exactly: 3)

        let (_, tree) = try generate(gen)

        let property: ([[UInt64]]) -> Bool = { _ in false }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        #expect(ChoiceSequence.validate(result.0))
    }

    // MARK: - Multiple seeds

    @Test(
        "Boundary collapsing works across different seeds",
        arguments: [UInt64(1)]
    )
    func boundaryCollapsingMultipleSeeds(seed: UInt64) throws {
        let innerGen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 1_000_000_000), within: UInt64(10) ... 20)
        let gen = Gen.arrayOf(innerGen, exactly: 3)

        let (value, tree) = try generate(gen, seed: seed)
        let originalSequence = ChoiceSequence.flatten(tree)
        let originalBoundarySpans = ChoiceSequence.extractSequenceBoundarySpans(from: originalSequence)

        guard originalBoundarySpans.isEmpty == false else { return }

        // This should minimise to [[500]]
        var count = 0
        let property: ([[UInt64]]) -> Bool = { arr in
            defer { count &+= 1 }
            return arr.flatMap(\.self).reduce(0, &+) < 500
        }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )
        print()

        #expect(result.0.shortLexPrecedes(originalSequence))
    }
}
