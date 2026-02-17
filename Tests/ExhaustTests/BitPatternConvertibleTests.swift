//
//  BitPatternConvertibleTests.swift
//  ExhaustTests
//
//  Tests for BitPatternConvertible implementations, particularly Int.
//

@testable import Exhaust
import Testing

@Suite("BitPattern Conversion")
struct BitPatternConvertibleTests {
    @Test("Int BitPatternConvertible round-trip for Int.min")
    func intMinRoundTrip() {
        let intMin = Int.min
        let bitPattern = intMin.bitPattern64

        // Verify round-trip (don't care about specific bit pattern value)
        let reconstructed = Int(bitPattern64: bitPattern)
        #expect(reconstructed == intMin)
    }

    @Test("Int BitPatternConvertible round-trip for Int.max")
    func intMaxRoundTrip() {
        let intMax = Int.max
        let bitPattern = intMax.bitPattern64

        // Verify round-trip (don't care about specific bit pattern value)
        let reconstructed = Int(bitPattern64: bitPattern)
        #expect(reconstructed == intMax)
    }

    @Test("Int BitPatternConvertible round-trip for zero")
    func intZeroRoundTrip() {
        let zero = 0
        let bitPattern = zero.bitPattern64

        // Verify round-trip (don't care about specific bit pattern value)
        let reconstructed = Int(bitPattern64: bitPattern)
        #expect(reconstructed == zero)
    }

    @Test("Int BitPatternConvertible round-trip for various values")
    func intBitPatternRoundTrip() {
        let testValues = [Int.min, Int.min + 1, -1000, -1, 0, 1, 1000, Int.max - 1, Int.max]

        for value in testValues {
            let bitPattern = value.bitPattern64
            let reconstructed = Int(bitPattern64: bitPattern)
            #expect(reconstructed == value, "Round-trip failed for \(value): got \(reconstructed)")
        }
    }

    @Test("Int BitPatternConvertible uses full UInt64 range")
    func intBitPatternUsesFullRange() {
        #expect(Int.bitPatternRanges == [UInt64.min ... UInt64.max])
    }

    @Test("UInt64 to Int mapping round-trip consistency")
    func uInt64ToIntMappingRoundTrip() {
        // Test that we can convert any UInt64 to Int and back
        let testValues: [UInt64] = [
            UInt64.min,
            1,
            UInt64.max / 4,
            UInt64.max / 2,
            UInt64.max / 2 + 1,
            UInt64.max - 1,
            UInt64.max,
        ]

        for bitPattern in testValues {
            let intValue = Int(bitPattern64: bitPattern)
            let reconstructed = intValue.bitPattern64
            #expect(reconstructed == bitPattern, "Round-trip failed for UInt64(\(bitPattern)): got \(reconstructed)")
        }
    }

    @Test("Float BitPatternConvertible round-trip for special values")
    func floatSpecialValuesRoundTrip() throws {
        let testValues: [Float] = [
            Float.zero,
            -Float.zero,
            1.0,
            -1.0,
            Float.pi,
            -Float.pi,
            Float.greatestFiniteMagnitude,
            -Float.greatestFiniteMagnitude,
            Float.leastNormalMagnitude,
            -Float.leastNormalMagnitude,
        ]

        for value in testValues {
            let bitPattern = value.bitPattern64
            let reconstructed = Float(bitPattern64: bitPattern)
            #expect(reconstructed == value, "Round-trip failed for Float(\(value)): got \(reconstructed)")
        }

        try PropertyTest.test(Float.arbitrary) { val in
            Float(bitPattern64: val.bitPattern64) == val
        }
    }

    @Test("Float BitPatternConvertible round-trip for infinity and NaN")
    func floatInfinityAndNaNRoundTrip() {
        let testValues: [Float] = [
            Float.infinity,
            -Float.infinity,
            Float.nan,
        ]

        for value in testValues {
            let bitPattern = value.bitPattern64
            let reconstructed = Float(bitPattern64: bitPattern)

            if value.isNaN {
                #expect(reconstructed.isNaN, "NaN round-trip failed")
            } else {
                #expect(reconstructed == value, "Round-trip failed for Float(\(value)): got \(reconstructed)")
            }
        }
    }

    @Test("Property test Float bit pattern representation is sequential with size")
    func propertyTestFloatBitPatternSequentiality() throws {
        let gen = Gen.zip(
            Gen.choose(in: -Float.greatestFiniteMagnitude ... 0),
            Gen.choose(in: 1 ... Float.greatestFiniteMagnitude.nextDown)
        )
        try PropertyTest.test(gen) { low, high in
            low.bitPattern64 < high.bitPattern64
        }
    }

    @Test("Double BitPatternConvertible round-trip for special values")
    func doubleSpecialValuesRoundTrip() throws {
        let testValues: [Double] = [
            Double.zero,
            -Double.zero,
            1.0,
            -1.0,
            Double.pi,
            -Double.pi,
            Double.greatestFiniteMagnitude,
            -Double.greatestFiniteMagnitude,
            Double.leastNormalMagnitude,
            -Double.leastNormalMagnitude,
        ]

        try PropertyTest.test(Double.arbitrary) { val in
            Double(bitPattern64: val.bitPattern64) == val
        }

        for value in testValues {
            let bitPattern = value.bitPattern64
            let reconstructed = Double(bitPattern64: bitPattern)
            #expect(reconstructed == value, "Round-trip failed for Double(\(value)): got \(reconstructed)")
        }
    }

    @Test("Double BitPatternConvertible round-trip for infinity and NaN")
    func doubleInfinityAndNaNRoundTrip() {
        let testValues: [Double] = [
            Double.infinity,
            -Double.infinity,
            Double.nan,
        ]

        for value in testValues {
            let bitPattern = value.bitPattern64
            let reconstructed = Double(bitPattern64: bitPattern)

            if value.isNaN {
                #expect(reconstructed.isNaN, "NaN round-trip failed")
            } else {
                #expect(reconstructed == value, "Round-trip failed for Double(\(value)): got \(reconstructed)")
            }
        }
    }

    @Test("Property test Double bit pattern representation is sequential with size")
    func propertyTestDoubleBitPatternSequentiality() throws {
        let gen = Gen.zip(
            Gen.choose(in: -Double.greatestFiniteMagnitude ... 0),
            Gen.choose(in: 1 ... Double.greatestFiniteMagnitude.nextDown)
        )
        try PropertyTest.test(gen) { low, high in
            low.bitPattern64 < high.bitPattern64
        }
    }

    @Test("UInt64 to Float mapping round-trip consistency")
    func uInt64ToFloatMappingRoundTrip() throws {
        // Test that we can convert any UInt64 within Float range to Float and back
        let testValues: [UInt64] = [
            0,
            1,
            UInt64(UInt32.max) / 4,
            UInt64(UInt32.max) / 2,
            UInt64(UInt32.max) / 2 + 1,
            UInt64(UInt32.max) - 1,
            UInt64(UInt32.max),
        ]

        try PropertyTest.test(UInt64.arbitrary) { val in
            UInt64(bitPattern64: val.bitPattern64) == val
        }

        for bitPattern in testValues {
            let floatValue = Float(bitPattern64: bitPattern)
            let reconstructed = floatValue.bitPattern64
            #expect(reconstructed == bitPattern, "Round-trip failed for UInt64(\(bitPattern)): got \(reconstructed)")
        }
    }

    @Test("UInt64 to Double mapping round-trip consistency")
    func uInt64ToDoubleMappingRoundTrip() {
        // Test that we can convert any UInt64 to Double and back
        let testValues: [UInt64] = [
            UInt64.min,
            1,
            UInt64.max / 4,
            UInt64.max / 2,
            UInt64.max / 2 + 1,
            UInt64.max - 1,
            UInt64.max,
        ]

        for bitPattern in testValues {
            let doubleValue = Double(bitPattern64: bitPattern)
            let reconstructed = doubleValue.bitPattern64
            #expect(reconstructed == bitPattern, "Round-trip failed for UInt64(\(bitPattern)): got \(reconstructed)")
        }
    }

    // MARK: - Signed Integer Tests

    @Test("Int8 BitPatternConvertible round-trip")
    func int8BitPatternRoundTrip() throws {
        let testValues: [Int8] = [Int8.min, -1, 0, 1, Int8.max]

        try PropertyTest.test(Int8.arbitrary) { val in
            Int8(bitPattern64: val.bitPattern64) == val
        }

        for value in testValues {
            let bitPattern = value.bitPattern64
            let reconstructed = Int8(bitPattern64: bitPattern)
            #expect(reconstructed == value, "Round-trip failed for Int8(\(value)): got \(reconstructed)")
        }
    }

    @Test("Int16 BitPatternConvertible round-trip")
    func int16BitPatternRoundTrip() throws {
        let testValues: [Int16] = [Int16.min, -1000, -1, 0, 1, 1000, Int16.max]

        try PropertyTest.test(Int16.arbitrary) { val in
            Int16(bitPattern64: val.bitPattern64) == val
        }

        for value in testValues {
            let bitPattern = value.bitPattern64
            let reconstructed = Int16(bitPattern64: bitPattern)
            #expect(reconstructed == value, "Round-trip failed for Int16(\(value)): got \(reconstructed)")
        }
    }

    @Test("Int32 BitPatternConvertible round-trip")
    func int32BitPatternRoundTrip() throws {
        let testValues: [Int32] = [Int32.min, -100_000, -1, 0, 1, 100_000, Int32.max]

        try PropertyTest.test(Int32.arbitrary) { val in
            Int32(bitPattern64: val.bitPattern64) == val
        }

        for value in testValues {
            let bitPattern = value.bitPattern64
            let reconstructed = Int32(bitPattern64: bitPattern)
            #expect(reconstructed == value, "Round-trip failed for Int32(\(value)): got \(reconstructed)")
        }
    }

    @Test("Int64 BitPatternConvertible round-trip")
    func int64BitPatternRoundTrip() throws {
        let testValues: [Int64] = [Int64.min, -1_000_000_000, -1, 0, 1, 1_000_000_000, Int64.max]

        try PropertyTest.test(Int64.arbitrary) { val in
            Int64(bitPattern64: val.bitPattern64) == val
        }

        for value in testValues {
            let bitPattern = value.bitPattern64
            let reconstructed = Int64(bitPattern64: bitPattern)
            #expect(reconstructed == value, "Round-trip failed for Int64(\(value)): got \(reconstructed)")
        }
    }

    @Test("Property test Int64 bit pattern representation is sequential with size")
    func propertyTestSignedIntegerBitPatternSequentiality() throws {
        let gen = Gen.zip(
            Gen.choose(in: Int64.min ... 0),
            Gen.choose(in: 1 ... Int64.max)
        )
        try PropertyTest.test(gen) { low, high in
            low.bitPattern64 < high.bitPattern64
        }
    }

    // MARK: - Unsigned Integer Tests

    @Test("UInt8 BitPatternConvertible round-trip")
    func uInt8BitPatternRoundTrip() {
        let testValues: [UInt8] = [UInt8.min, 1, 127, 128, 255]

        for value in testValues {
            let bitPattern = value.bitPattern64
            let reconstructed = UInt8(bitPattern64: bitPattern)
            #expect(reconstructed == value, "Round-trip failed for UInt8(\(value)): got \(reconstructed)")
        }
    }

    @Test("UInt16 BitPatternConvertible round-trip")
    func uInt16BitPatternRoundTrip() {
        let testValues: [UInt16] = [UInt16.min, 1, 1000, 32767, 32768, UInt16.max]

        for value in testValues {
            let bitPattern = value.bitPattern64
            let reconstructed = UInt16(bitPattern64: bitPattern)
            #expect(reconstructed == value, "Round-trip failed for UInt16(\(value)): got \(reconstructed)")
        }
    }

    @Test("UInt32 BitPatternConvertible round-trip")
    func uInt32BitPatternRoundTrip() {
        let testValues: [UInt32] = [UInt32.min, 1, 100_000, 2_147_483_647, 2_147_483_648, UInt32.max]

        for value in testValues {
            let bitPattern = value.bitPattern64
            let reconstructed = UInt32(bitPattern64: bitPattern)
            #expect(reconstructed == value, "Round-trip failed for UInt32(\(value)): got \(reconstructed)")
        }
    }

    @Test("UInt64 BitPatternConvertible round-trip")
    func uInt64BitPatternRoundTrip() {
        let testValues: [UInt64] = [UInt64.min, 1, 1_000_000_000, UInt64.max / 2, UInt64.max]

        for value in testValues {
            let bitPattern = value.bitPattern64
            let reconstructed = UInt64(bitPattern64: bitPattern)
            #expect(reconstructed == value, "Round-trip failed for UInt64(\(value)): got \(reconstructed)")
        }
    }

    @Test("UInt BitPatternConvertible round-trip")
    func uIntBitPatternRoundTrip() {
        let testValues: [UInt] = [UInt.min, 1, 1_000_000, UInt.max / 2, UInt.max]

        for value in testValues {
            let bitPattern = value.bitPattern64
            let reconstructed = UInt(bitPattern64: bitPattern)
            #expect(reconstructed == value, "Round-trip failed for UInt(\(value)): got \(reconstructed)")
        }
    }
}
