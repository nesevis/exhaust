//
//  BitPatternConvertibleTests.swift
//  ExhaustTests
//
//  Tests for BitPatternConvertible implementations, particularly Int.
//
//  NOTE: All #exhaust calls converted to exhaustCheck helper since #exhaust is Exhaust-only.
//

import Testing
@testable import ExhaustCore

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
        // #exhaust was Exhaust-only; using exhaustCheck helper
        exhaustCheck(Gen.choose() as ReflectiveGenerator<Int>) { value in
            Int(bitPattern64: value.bitPattern64) == value
        }
    }

    @Test("Int BitPatternConvertible uses full UInt64 range")
    func intBitPatternUsesFullRange() {
        #expect(Int.bitPatternRanges == [UInt64.min ... UInt64.max])
    }

    @Test("UInt64 to Int mapping round-trip consistency")
    func uInt64ToIntMappingRoundTrip() {
        exhaustCheck(Gen.choose() as ReflectiveGenerator<UInt64>) { bitPattern in
            Int(bitPattern64: bitPattern).bitPattern64 == bitPattern
        }
    }

    @Test("Float BitPatternConvertible round-trip for special values")
    func floatSpecialValuesRoundTrip() {
        exhaustCheck(Gen.choose() as ReflectiveGenerator<Float>) { val in
            val.isNaN || Float(bitPattern64: val.bitPattern64) == val
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
    func propertyTestFloatBitPatternSequentiality() {
        let gen = Gen.zip(
            Gen.choose(in: -Float.greatestFiniteMagnitude ... Float(0)),
            Gen.choose(in: Float(1) ... Float.greatestFiniteMagnitude.nextDown),
        )
        exhaustCheck(gen) { low, high in
            low.bitPattern64 < high.bitPattern64
        }
    }

    @Test("Double BitPatternConvertible round-trip for special values")
    func doubleSpecialValuesRoundTrip() {
        exhaustCheck(Gen.choose() as ReflectiveGenerator<Double>) { val in
            val.isNaN || Double(bitPattern64: val.bitPattern64) == val
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
    func propertyTestDoubleBitPatternSequentiality() {
        let gen = Gen.zip(
            Gen.choose(in: -Double.greatestFiniteMagnitude ... 0),
            Gen.choose(in: 1.0 ... Double.greatestFiniteMagnitude.nextDown),
        )
        exhaustCheck(gen) { low, high in
            low.bitPattern64 < high.bitPattern64
        }
    }

    @Test("UInt64 to Float mapping round-trip consistency")
    func uInt64ToFloatMappingRoundTrip() {
        exhaustCheck(Gen.choose(in: UInt64(0) ... UInt64(UInt32.max))) { bitPattern in
            Float(bitPattern64: bitPattern).bitPattern64 == bitPattern
        }
    }

    @Test("UInt64 to Double mapping round-trip consistency")
    func uInt64ToDoubleMappingRoundTrip() {
        exhaustCheck(Gen.choose() as ReflectiveGenerator<UInt64>) { bitPattern in
            Double(bitPattern64: bitPattern).bitPattern64 == bitPattern
        }
    }

    // MARK: - Signed Integer Tests

    @Test("Int8 BitPatternConvertible round-trip")
    func int8BitPatternRoundTrip() {
        exhaustCheck(Gen.choose() as ReflectiveGenerator<Int8>) { val in
            Int8(bitPattern64: val.bitPattern64) == val
        }
    }

    @Test("Int16 BitPatternConvertible round-trip")
    func int16BitPatternRoundTrip() {
        exhaustCheck(Gen.choose() as ReflectiveGenerator<Int16>) { val in
            Int16(bitPattern64: val.bitPattern64) == val
        }
    }

    @Test("Int32 BitPatternConvertible round-trip")
    func int32BitPatternRoundTrip() {
        exhaustCheck(Gen.choose() as ReflectiveGenerator<Int32>) { val in
            Int32(bitPattern64: val.bitPattern64) == val
        }
    }

    @Test("Int64 BitPatternConvertible round-trip")
    func int64BitPatternRoundTrip() {
        exhaustCheck(Gen.choose() as ReflectiveGenerator<Int64>) { val in
            Int64(bitPattern64: val.bitPattern64) == val
        }
    }

    @Test("Property test Int64 bit pattern representation is sequential with size")
    func propertyTestSignedIntegerBitPatternSequentiality() {
        let gen = Gen.zip(
            Gen.choose(in: Int64.min ... Int64(0)),
            Gen.choose(in: Int64(1) ... Int64.max),
        )
        exhaustCheck(gen) { low, high in
            low.bitPattern64 < high.bitPattern64
        }
    }

    // MARK: - Unsigned Integer Tests

    @Test("UInt8 BitPatternConvertible round-trip")
    func uInt8BitPatternRoundTrip() {
        exhaustCheck(Gen.choose() as ReflectiveGenerator<UInt8>) { val in
            UInt8(bitPattern64: val.bitPattern64) == val
        }
    }

    @Test("UInt16 BitPatternConvertible round-trip")
    func uInt16BitPatternRoundTrip() {
        exhaustCheck(Gen.choose() as ReflectiveGenerator<UInt16>) { val in
            UInt16(bitPattern64: val.bitPattern64) == val
        }
    }

    @Test("UInt32 BitPatternConvertible round-trip")
    func uInt32BitPatternRoundTrip() {
        exhaustCheck(Gen.choose() as ReflectiveGenerator<UInt32>) { val in
            UInt32(bitPattern64: val.bitPattern64) == val
        }
    }

    @Test("UInt64 BitPatternConvertible round-trip")
    func uInt64BitPatternRoundTrip() {
        exhaustCheck(Gen.choose() as ReflectiveGenerator<UInt64>) { val in
            UInt64(bitPattern64: val.bitPattern64) == val
        }
    }

    @Test("UInt BitPatternConvertible round-trip")
    func uIntBitPatternRoundTrip() {
        exhaustCheck(Gen.choose() as ReflectiveGenerator<UInt>) { val in
            UInt(bitPattern64: val.bitPattern64) == val
        }
    }
}

// MARK: - Helpers

/// Replacement for `#exhaust` macro: generates values and checks a property holds for all of them.
private func exhaustCheck<T>(
    _ gen: ReflectiveGenerator<T>,
    maxIterations: UInt64 = 100,
    seed: UInt64 = 42,
    property: (T) -> Bool,
) {
    var iter = ValueInterpreter(gen, seed: seed, maxRuns: maxIterations)
    while let value = iter.next() {
        #expect(property(value), "Property failed for value: \(value)")
    }
}
