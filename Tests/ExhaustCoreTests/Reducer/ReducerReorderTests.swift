//
//  ReducerReorderTests.swift
//  ExhaustTests
//
//  Tests for Pass 6 of Interpreters.reduce: sibling value reordering.
//  Pass 6 reorders sibling elements within sequences so that shrunk outputs
//  are normalized (e.g. [3, 1, 2] → [1, 2, 3]).
//

import ExhaustCore
import Testing

// MARK: - Helpers

/// Generate a value and its choice tree from a generator with a given seed.
private func generate<Output>(
    _ gen: ReflectiveGenerator<Output>,
    seed: UInt64 = 42,
    iteration: Int = 0
) throws -> (value: Output, tree: ChoiceTree) {
    var iter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed)
    return try #require(iter.prefix(iteration + 1).last)
}

// MARK: - Tests

@Suite("Reducer Pass 6: sibling value reordering")
struct ReducerReorderTests {
    @Test("Unsorted array is reordered to sorted")
    func unsortedArrayReordered() throws {
        // Generate [UInt64] with values that will likely be out of order
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 3)

        // Try seeds until we find one that produces an unsorted array
        var foundResult: (value: [UInt64], tree: ChoiceTree)?
        for seed: UInt64 in 0 ... 100 {
            let (value, tree) = try generate(gen, seed: seed, iteration: 5)
            if value != value.sorted() {
                foundResult = (value, tree)
                break
            }
        }
        let (originalValue, tree) = try #require(foundResult)
        #expect(originalValue != originalValue.sorted())

        // Property: always fails → reducer can freely reorder
        let property: ([UInt64]) -> Bool = { _ in false }

        let result = try #require(
            try Interpreters.bonsaiReduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        // The output should be sorted (or at least simpler than the original)
        #expect(result.1.sorted() == result.1)
    }

    @Test("Already-sorted sequence is not changed by reorder pass")
    func alreadySortedNoChange() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 3)

        // Find a seed that produces an already-sorted array
        var foundResult: (value: [UInt64], tree: ChoiceTree)?
        for seed: UInt64 in 0 ... 1000 {
            let (value, tree) = try generate(gen, seed: seed, iteration: 5)
            if value == value.sorted(), value != [0, 0, 0] {
                foundResult = (value, tree)
                break
            }
        }
        // If no naturally sorted seed is found, that's fine — skip
        guard let (originalValue, tree) = foundResult else { return }

        // Property always fails
        let property: ([UInt64]) -> Bool = { _ in false }

        let result = try #require(
            try Interpreters.bonsaiReduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        // Values should still be sorted after reduction
        #expect(result.1 == result.1.sorted())
    }

    @Test("Reordering that would cause property to pass is not accepted")
    func reorderingRejectedWhenPropertyPasses() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 3)

        var foundResult: (value: [UInt64], tree: ChoiceTree)?
        for seed: UInt64 in 0 ... 100 {
            let (value, tree) = try generate(gen, seed: seed, iteration: 5)
            if value != value.sorted() {
                foundResult = (value, tree)
                break
            }
        }
        let (_, tree) = try #require(foundResult)

        // Property fails ONLY when array is not sorted
        // So reordering to sorted would make the property pass → must be rejected
        let property: ([UInt64]) -> Bool = { arr in
            arr == arr.sorted()
        }

        let result = try #require(
            try Interpreters.bonsaiReduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        // The output must still fail the property
        #expect(property(result.1) == false)
        // Therefore the array must NOT be sorted
        #expect(result.1 != result.1.sorted())
    }

    @Test("Reduced sequence from reorder pass has balanced brackets")
    func reducedSequenceBalanced() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 1000), exactly: 5)

        let (_, tree) = try generate(gen, seed: 7, iteration: 5)

        let property: ([UInt64]) -> Bool = { _ in false }

        let result = try #require(
            try Interpreters.bonsaiReduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        #expect(ChoiceSequence.validate(result.0))
    }

    @Test("Materialized output from reordered sequence matches stored output")
    func materializedMatchesStored() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 4)

        let (_, tree) = try generate(gen, seed: 13, iteration: 5)

        let property: ([UInt64]) -> Bool = { _ in false }

        let result = try #require(
            try Interpreters.bonsaiReduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        guard case let .success(rematerialized, _, _) = ReductionMaterializer.materialize(gen, prefix: result.0, mode: .exact, fallbackTree: tree) else {
            Issue.record("Expected .success")
            return
        }

        #expect(result.1 == rematerialized)
    }
}
