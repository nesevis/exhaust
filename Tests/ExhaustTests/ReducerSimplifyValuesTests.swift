//
//  ReducerSimplifyValuesTests.swift
//  ExhaustTests
//
//  Tests for Pass 3 of Interpreters.reduce: simplify values to semantic simplest.
//  Pass 3 tries replacing each .value entry with its semantically simplest form
//  (0 for numbers, "a" for characters) using find_integer for batching.
//

import Testing
@testable import Exhaust

// MARK: - Helpers

/// Generate a value and its choice tree from a generator with a given seed.
private func generate<Output>(
    _ gen: ReflectiveGenerator<Output>,
    seed: UInt64 = 42
) throws -> (value: Output, tree: ChoiceTree) {
    try #require(
        Array(ValueAndChoiceTreeInterpreter(gen, seed: seed).prefix(1)).first
    )
}

// MARK: - ChoiceValue.semanticSimplest

@Suite("ChoiceValue.semanticSimplest")
struct SemanticSimplestTests {

    @Test("Unsigned simplest is 0")
    func unsignedSimplest() {
        let value = ChoiceValue.unsigned(42, UInt64.self)
        let simplest = value.semanticSimplest
        #expect(simplest == .unsigned(0, UInt64.self))
    }

    @Test("Unsigned 0 is already simplest")
    func unsignedAlreadySimplest() {
        let value = ChoiceValue.unsigned(0, UInt64.self)
        #expect(value.semanticSimplest == value)
    }

    @Test("Signed simplest is 0")
    func signedSimplest() {
        let value = ChoiceValue(Int64(42), tag: .int64)
        let simplest = value.semanticSimplest
        if case let .signed(int64Val, _, _) = simplest {
            #expect(int64Val == 0)
        } else {
            Issue.record("Expected .signed case")
        }
    }

    @Test("Float simplest is 0.0")
    func floatSimplest() {
        let value = ChoiceValue(3.14, tag: .double)
        let simplest = value.semanticSimplest
        if case let .floating(doubleVal, _, _) = simplest {
            #expect(doubleVal == 0.0)
        } else {
            Issue.record("Expected .floating case")
        }
    }

    @Test("Character simplest is 'a'")
    func characterSimplest() {
        let value = ChoiceValue.character("Z")
        let simplest = value.semanticSimplest
        #expect(simplest == .character("a"))
    }

    @Test("Character 'a' is already simplest")
    func characterAlreadySimplest() {
        let value = ChoiceValue.character("a")
        #expect(value.semanticSimplest == value)
    }
}

// MARK: - ShortlexKey

@Suite("ChoiceValue.shortlexKey")
struct ShortlexKeyTests {

    @Test("Signed zero has smallest shortlexKey")
    func signedZeroIsSmallest() {
        let zero = ChoiceValue(Int64(0), tag: .int64)
        let positive = ChoiceValue(Int64(1), tag: .int64)
        let negative = ChoiceValue(Int64(-1), tag: .int64)
        #expect(zero.shortlexKey < positive.shortlexKey)
        #expect(zero.shortlexKey < negative.shortlexKey)
    }

    @Test("Signed shortlexKey: opposite signs with same magnitude have off-by-one keys")
    func signedOppositeSignsEqual() {
        let pos = ChoiceValue(Int64(42), tag: .int64)
        let neg = ChoiceValue(Int64(-42), tag: .int64)
        #expect(pos.shortlexKey == neg.shortlexKey + 1)
        #expect(pos.shortlexKey == 84)
    }

    @Test("Unsigned shortlexKey equals bitPattern64")
    func unsignedKeyEqualsBitPattern() {
        let value = ChoiceValue.unsigned(42, UInt64.self)
        #expect(value.shortlexKey == value.bitPattern64)
    }

    @Test("Signed semanticSimplest has shortlexKey 0")
    func signedSimplestHasZeroKey() {
        let value = ChoiceValue(Int64(42), tag: .int64)
        #expect(value.semanticSimplest.shortlexKey == 0)
    }

    // MARK: Signed boundary values

    @Test("Signed Int64.min and Int64.max have large shortlexKeys")
    func signedBoundaryValues() {
        let min = ChoiceValue(Int64.min, tag: .int64)
        let max = ChoiceValue(Int64.max, tag: .int64)
        let zero = ChoiceValue(Int64(0), tag: .int64)
        #expect(zero.shortlexKey < min.shortlexKey)
        #expect(zero.shortlexKey < max.shortlexKey)
//        #expect(max.shortlexKey == UInt64(Int64.max))
//        // Int64.min has magnitude Int64.max + 1
//        #expect(min.shortlexKey == UInt64(Int64.max) + 1)
    }

    // MARK: Other signed widths

    @Test("Signed shortlexKey works for Int8")
    func shortlexKeyInt8() {
        let values: [Int8] = [0, -1, 1, -2, 2]
        let keys = values.map { ChoiceValue($0, tag: .int8).shortlexKey }
        #expect(keys == [0, 1, 2, 3, 4])
    }

    @Test("Signed shortlexKey works for Int32")
    func shortlexKeyInt32() {
        let zero = ChoiceValue(Int32(0), tag: .int32)
        let pos = ChoiceValue(Int32(1000), tag: .int32)
        let neg = ChoiceValue(Int32(-1000), tag: .int32)
        #expect(zero.shortlexKey < pos.shortlexKey)
        #expect(zero.shortlexKey < neg.shortlexKey)
        #expect(pos.shortlexKey > neg.shortlexKey)
    }

    // MARK: Floating point

    @Test("Float shortlexKey: 0.0 is the smallest key")
    func floatZeroIsSmallest() {
        let zero = ChoiceValue(0.0, tag: .double)
        let pos = ChoiceValue(1.0, tag: .double)
        let neg = ChoiceValue(-1.0, tag: .double)
        #expect(zero.shortlexKey == 0)
        #expect(zero.shortlexKey < pos.shortlexKey)
        #expect(zero.shortlexKey < neg.shortlexKey)
    }

    @Test("Float shortlexKey: opposite signs with same magnitude have equal keys")
    func floatOppositeSignsEqual() {
        let pos = ChoiceValue(3.14, tag: .double)
        let neg = ChoiceValue(-3.14, tag: .double)
        #expect(pos.shortlexKey == neg.shortlexKey)
    }

    @Test("Float shortlexKey: -0.0 maps to 0")
    func floatNegativeZero() {
        let negZero = ChoiceValue(-0.0, tag: .double)
        #expect(negZero.shortlexKey == 0)
    }

    @Test("Float shortlexKey orders by distance from zero")
    func floatDistanceFromZeroOrdering() {
        let small = ChoiceValue(0.001, tag: .double)
        let medium = ChoiceValue(1.0, tag: .double)
        let large = ChoiceValue(1000.0, tag: .double)
        #expect(small.shortlexKey < medium.shortlexKey)
        #expect(medium.shortlexKey < large.shortlexKey)

        // Negative values ordered by magnitude too
        let negSmall = ChoiceValue(-0.001, tag: .double)
        let negLarge = ChoiceValue(-1000.0, tag: .double)
        #expect(negSmall.shortlexKey < negLarge.shortlexKey)
    }

    @Test("Float shortlexKey: infinity has large key, NaN has largest")
    func floatSpecialValues() {
        let large = ChoiceValue(Double.greatestFiniteMagnitude, tag: .double)
        let inf = ChoiceValue(Double.infinity, tag: .double)
        let nan = ChoiceValue(Double.nan, tag: .double)
        #expect(large.shortlexKey < inf.shortlexKey)
        #expect(inf.shortlexKey < nan.shortlexKey)
    }
}

// MARK: - Reducer Pass 3 Tests

@Suite("Reducer Pass 3: simplify values")
struct ReducerSimplifyValuesTests {

    @Test("Values are simplified when property fails for 3-element arrays")
    func valuesSimplifiedWhenAlwaysFailing() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0)...100), exactly: 3)

        let (_, tree) = try generate(gen)

        // Property fails only for 3-element arrays — prevents element deletion,
        // but allows Pass 3 to simplify values within the array
        var iterationCount = 0
        let property: ([UInt64]) -> Bool = { arr in
            iterationCount += 1
            return arr.count != 3
        }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        #expect(iterationCount > 0)
        #expect(result.1.count == 3)
        #expect(result.1.allSatisfy { $0 == 0 })
    }

    @Test("Adaptive probe batches simplification around a load-bearing value")
    func adaptiveProbeBatchesAroundLoadBearing() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0)...100), exactly: 5)

        let (_, tree) = try generate(gen)

        // The middle element (index 2) must stay > 0 for the property to fail.
        // All other values are free to simplify to 0.
        var evaluationCount = 0
        let property: ([UInt64]) -> Bool = { arr in
            evaluationCount += 1
            guard arr.count == 5 else { return true }
            return arr[2] == 0
        }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )
        print()

        #expect(result.1.count == 5)
        // Non-load-bearing values simplified to 0
        #expect(result.1[0] == 0)
        #expect(result.1[1] == 0)
        #expect(result.1[3] == 0)
        #expect(result.1[4] == 0)
        // Load-bearing value preserved (simplified to 1, the smallest non-zero)
        #expect(result.1[2] >= 1)
    }

    @Test("Reduced sequence is shortlex-smaller after simplification")
    func reducedSequenceIsSmaller() throws {
        let gen = Gen.choose(in: UInt64(0)...1000)

        let (value, tree) = try generate(gen)
        // Only test if the generated value is not already 0
        try #require(value > 0)

        let originalSequence = ChoiceSequence.flatten(tree)

        // Property always fails → value should simplify to 0
        let property: (UInt64) -> Bool = { _ in false }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        #expect(result.0.shortLexPrecedes(originalSequence))
        #expect(result.1 == 0)
    }

    @Test("Simplification preserves property failure")
    func simplificationPreservesFailure() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0)...100), exactly: 5)

        let (_, tree) = try generate(gen)

        // Property fails when sum > 0 (at least one non-zero value)
        let property: ([UInt64]) -> Bool = { arr in
            arr.reduce(0, +) == 0
        }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        // The reduced output must still fail the property
        #expect(property(result.1) == false)
    }

    @Test("Values already at simplest are not changed")
    func alreadySimplestUnchanged() throws {
        let gen = Gen.choose(in: UInt64(0)...100)

        let (_, tree) = try generate(gen)
        let originalSequence = ChoiceSequence.flatten(tree)

        // Property always passes → nothing can be simplified
        let property: (UInt64) -> Bool = { _ in true }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        #expect(result.0 == originalSequence)
    }

    @Test("Simplification works with positive signed integers")
    func signedIntegerSimplification() throws {
        // Use a positive-only range so 0 is shortlex-smaller than generated values
        let gen = Gen.choose(in: Int64(0)...100)

        let (value, tree) = try generate(gen)
        try #require(value > 0)

        // Property always fails
        let property: (Int64) -> Bool = { _ in false }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        // The output should be 0 (semantic simplest for signed)
        #expect(result.1 == 0)
    }

    @Test("Signed values in range containing zero simplify to 0")
    func signedValuesSimplifyToZero() throws {
        let gen = Gen.choose(in: Int64(-100)...100)

        let (value, tree) = try generate(gen)
        try #require(value != 0)

        let property: (Int64) -> Bool = { _ in false }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        #expect(result.1 == 0)
    }

    @Test("Simplification works with characters")
    func characterSimplification() throws {
        let gen = Gen.arrayOf(Gen.choose(in: Character("a")...Character("z")), exactly: 3)

        let (_, tree) = try generate(gen)

        // Property always fails
        let property: ([Character]) -> Bool = { _ in false }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        // All characters should be "a"
        #expect(result.1.allSatisfy { $0 == "a" })
    }

    @Test("Partial simplification when some values are failure-relevant")
    func partialSimplification() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0)...100), exactly: 3)

        let (_, tree) = try generate(gen)
        let originalSequence = ChoiceSequence.flatten(tree)

        // Property fails only when sum > 50 — some values must stay non-zero
        let property: ([UInt64]) -> Bool = { arr in
            arr.reduce(0, +) <= 50
        }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        // Should be simpler than original
        #expect(result.0.shortLexPrecedes(originalSequence))
        // But must still fail the property
        #expect(property(result.1) == false)
    }

    @Test("Reduced sequence has balanced brackets after simplification")
    func balancedBracketsAfterSimplification() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0)...100), exactly: 4)

        let (_, tree) = try generate(gen)

        let property: ([UInt64]) -> Bool = { _ in false }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        #expect(ChoiceSequence.validate(result.0))
    }

    @Test("Materialized output matches reduced sequence")
    func materializedOutputMatches() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0)...100), exactly: 3)

        let (_, tree) = try generate(gen)

        let property: ([UInt64]) -> Bool = { _ in false }

        let result = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        let rematerialized = try #require(
            try Interpreters.materialize(gen, with: tree, using: result.0)
        )

        #expect(result.1 == rematerialized)
    }
}
