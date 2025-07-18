//
//  BitPatternConvertibleTests.swift
//  ExhaustTests
//
//  Tests for BitPatternConvertible implementations, particularly Int.
//

import Testing
@testable import Exhaust

@Test("Int BitPatternConvertible round-trip for Int.min")
func testIntMinRoundTrip() {
    let intMin = Int.min
    let bitPattern = intMin.bitPattern64
    
    // Verify round-trip (don't care about specific bit pattern value)
    let reconstructed = Int(bitPattern: bitPattern)
    #expect(reconstructed == intMin)
}

@Test("Int BitPatternConvertible round-trip for Int.max")
func testIntMaxRoundTrip() {
    let intMax = Int.max
    let bitPattern = intMax.bitPattern64
    
    // Verify round-trip (don't care about specific bit pattern value)
    let reconstructed = Int(bitPattern: bitPattern)
    #expect(reconstructed == intMax)
}

@Test("Int BitPatternConvertible round-trip for zero")
func testIntZeroRoundTrip() {
    let zero = 0
    let bitPattern = zero.bitPattern64
    
    // Verify round-trip (don't care about specific bit pattern value)
    let reconstructed = Int(bitPattern: bitPattern)
    #expect(reconstructed == zero)
}

@Test("Int BitPatternConvertible round-trip for various values")
func testIntBitPatternRoundTrip() {
    let testValues = [Int.min, Int.min + 1, -1000, -1, 0, 1, 1000, Int.max - 1, Int.max]
    
    for value in testValues {
        let bitPattern = value.bitPattern64
        let reconstructed = Int(bitPattern: bitPattern)
        #expect(reconstructed == value, "Round-trip failed for \(value): got \(reconstructed)")
    }
}

@Test("Int BitPatternConvertible uses full UInt64 range")
func testIntBitPatternUsesFullRange() {
    #expect(Int.bitPatternRange == UInt64.min...UInt64.max)
}

@Test("UInt64 to Int mapping round-trip consistency")
func testUInt64ToIntMappingRoundTrip() {
    // Test that we can convert any UInt64 to Int and back
    let testValues: [UInt64] = [
        UInt64.min, 
        1, 
        UInt64.max / 4,
        UInt64.max / 2, 
        UInt64.max / 2 + 1,
        UInt64.max - 1,
        UInt64.max
    ]
    
    for bitPattern in testValues {
        let intValue = Int(bitPattern: bitPattern)
        let reconstructed = intValue.bitPattern64
        #expect(reconstructed == bitPattern, "Round-trip failed for UInt64(\(bitPattern)): got \(reconstructed)")
    }
}