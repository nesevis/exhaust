//
//  ReducerSimplifyValuesTests.swift
//  ExhaustTests
//
//  Tests for Pass 3 of Interpreters.reduce: simplify values to semantic simplest.
//  Pass 3 tries replacing each .value entry with its semantically simplest form
//  (0 for numbers, "a" for characters) using find_integer for batching.
//

import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing

@Suite("Reducer Pass 3: simplify values")
struct ReducerSimplifyValuesTests {
    @Test("Values are simplified when property fails for 3-element arrays")
    func valuesSimplifiedWhenAlwaysFailing() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 3)

        let (_, tree) = try generate(gen)

        // Property fails only for 3-element arrays — prevents element deletion,
        // but allows Pass 3 to simplify values within the array
        var iterationCount = 0
        let property: ([UInt64]) -> Bool = { arr in
            iterationCount += 1
            return arr.count != 3
        }

        let (_, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property).counterexample
        )

        #expect(iterationCount > 0)
        #expect(output.count == 3)
        #expect(output.allSatisfy { $0 == 0 })
    }

    @Test("Adaptive probe batches simplification around a load-bearing value")
    func adaptiveProbeBatchesAroundLoadBearing() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 5)

        let (_, tree) = try generate(gen)

        // The middle element (index 2) must stay > 0 for the property to fail.
        // All other values are free to simplify to 0.
        var evaluationCount = 0
        let property: ([UInt64]) -> Bool = { arr in
            evaluationCount += 1
            guard arr.count == 5 else { return true }
            return arr[2] == 0
        }

        let (_, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property).counterexample
        )

        #expect(output.count == 5)
        // Non-load-bearing values simplified to 0
        #expect(output[0] == 0)
        #expect(output[1] == 0)
        #expect(output[3] == 0)
        #expect(output[4] == 0)
        // Load-bearing value preserved (simplified to 1, the smallest non-zero)
        #expect(output[2] >= 1)
    }

    @Test("Reduced sequence is shortlex-smaller after simplification")
    func reducedSequenceIsSmaller() throws {
        let gen = Gen.choose(in: UInt64(0) ... 1000)

        let (value, tree) = try generate(gen)
        // Only test if the generated value is not already 0
        try #require(value > 0)

        let originalSequence = ChoiceSequence.flatten(tree)

        // Property always fails → value should simplify to 0
        let property: (UInt64) -> Bool = { _ in false }

        let (sequence, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property).counterexample
        )

        #expect(sequence.shortLexPrecedes(originalSequence))
        #expect(output == 0)
    }

    @Test("Simplification preserves property failure")
    func simplificationPreservesFailure() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 5)

        let (_, tree) = try generate(gen)

        // Property fails when sum > 0 (at least one non-zero value)
        let property: ([UInt64]) -> Bool = { arr in
            arr.reduce(0, +) == 0
        }

        let (_, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property).counterexample
        )

        // The reduced output must still fail the property
        #expect(property(output) == false)
    }

    @Test("Values already at simplest are not changed")
    func alreadySimplestUnchanged() throws {
        let gen = Gen.choose(in: UInt64(0) ... 100)

        let (_, tree) = try generate(gen)

        // Property always passes → nothing can be simplified
        let property: (UInt64) -> Bool = { _ in true }

        let result = try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property)
        if case .reduced = result {
            Issue.record("Property always passes — reduction should not find an improvement")
        }
    }

    @Test("Simplification works with positive signed integers")
    func signedIntegerSimplification() throws {
        // Use a positive-only range so 0 is shortlex-smaller than generated values
        let gen = Gen.choose(in: Int64(0) ... 100)

        let (value, tree) = try generate(gen)
        try #require(value > 0)

        // Property always fails
        let property: (Int64) -> Bool = { _ in false }

        let (_, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property).counterexample
        )

        // The output should be 0 (semantic simplest for signed)
        #expect(output == 0)
    }

    @Test("Signed values in range containing zero simplify to 0")
    func signedValuesSimplifyToZero() throws {
        let gen = Gen.choose(in: Int64(-100) ... 100)

        let (value, tree) = try generate(gen)
        try #require(value != 0)

        let property: (Int64) -> Bool = { _ in false }

        let (_, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property).counterexample
        )

        #expect(output == 0)
    }

    @Test("Simplification works with characters")
    func characterSimplification() throws {
        let gen = Gen.arrayOf(
            charGen(from: CharacterSet(charactersIn: Unicode.Scalar(" ") ... Unicode.Scalar("z"))),
            exactly: 3
        )

        let (_, tree) = try generate(gen)

        // Property always fails
        let property: ([Character]) -> Bool = { _ in false }

        let (_, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property).counterexample
        )

        // All characters should be " "
        #expect(output.allSatisfy { $0 == " " })
    }

    @Test("Partial simplification when some values are failure-relevant")
    func partialSimplification() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 3)

        let (_, tree) = try generate(gen)
        let originalSequence = ChoiceSequence.flatten(tree)

        // Property fails only when sum > 50 — some values must stay non-zero
        let property: ([UInt64]) -> Bool = { arr in
            arr.reduce(0, +) <= 50
        }

        let (sequence, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property).counterexample
        )

        // Should be simpler than original
        #expect(sequence.shortLexPrecedes(originalSequence))
        // But must still fail the property
        #expect(property(output) == false)
    }

    @Test("Reduced sequence has balanced brackets after simplification")
    func balancedBracketsAfterSimplification() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 4)

        let (_, tree) = try generate(gen)

        let property: ([UInt64]) -> Bool = { _ in false }

        let (sequence, _) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property).counterexample
        )

        #expect(ChoiceSequence.validate(sequence))
    }

    @Test("Materialized output matches reduced sequence")
    func materializedOutputMatches() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 3)

        let (_, tree) = try generate(gen)

        let property: ([UInt64]) -> Bool = { _ in false }

        let (sequence, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property).counterexample
        )

        guard case let .success(rematerialized, _, _) = Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: tree) else {
            Issue.record("Expected .success")
            return
        }

        #expect(output == rematerialized)
    }
}

// MARK: - Helpers

private let reducerConfig = Interpreters.ReducerConfiguration(maxStalls: 2)
