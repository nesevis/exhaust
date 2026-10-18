//
//  ShortlexKeyTests.swift
//  ExhaustCoreTests
//
//  Unit tests for ChoiceValue.shortlexKey ordering across type tags. The ordering properties (totality, transitivity, antisymmetry) live in Interpreters/ShortlexOrderingPropertyTests.swift.
//

import ExhaustCore
import Testing

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
        let value = ChoiceValue(42 as UInt64, tag: .uint64)
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

    @Test("Float shortlexKey prefers simple integers before non-simple fractions")
    func floatDistanceFromZeroOrdering() {
        let nonSimpleFraction = ChoiceValue(0.001, tag: .double)
        let simpleSmallInteger = ChoiceValue(1.0, tag: .double)
        let simpleLargeInteger = ChoiceValue(1000.0, tag: .double)

        // Simple non-negative integers preserve natural ordering.
        #expect(simpleSmallInteger.shortlexKey < simpleLargeInteger.shortlexKey)

        // Non-simple fractions are ranked after simple integers.
        #expect(simpleSmallInteger.shortlexKey < nonSimpleFraction.shortlexKey)
        #expect(simpleLargeInteger.shortlexKey < nonSimpleFraction.shortlexKey)

        // Sign is ignored for equal magnitudes.
        let negSimpleLarge = ChoiceValue(-1000.0, tag: .double)
        #expect(negSimpleLarge.shortlexKey == simpleLargeInteger.shortlexKey)
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
