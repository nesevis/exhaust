//
//  ChoiceMetadataTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

import Testing
@testable import Exhaust

@Suite("ChoiceMetadata Functionality")
struct ChoiceMetadataTests {
    
    @Suite("Semantic Complexity")
    struct SemanticComplexityTests {
        
        @Test("Float complexity")
        func testFloatComplexity() {
            let metadata = ChoiceMetadata(
                validRanges: [0...UInt64(UInt32.max)],
                strategies: [.decimal, .minimal]
            )
            
            // Test positive float
            let positiveFloat: Float = 42.5
            let positiveComplexity = metadata.semanticComplexity(for: positiveFloat.bitPattern64)
            #expect(positiveComplexity == 42)
            
            // Test negative float
            let negativeFloat: Float = -42.5
            let negativeComplexity = metadata.semanticComplexity(for: negativeFloat.bitPattern64)
            #expect(negativeComplexity == 42)
            
            // Test zero
            let zeroFloat: Float = 0.0
            let zeroComplexity = metadata.semanticComplexity(for: zeroFloat.bitPattern64)
            #expect(zeroComplexity == 0)
            
            // Test NaN
            let nanFloat = Float.nan
            let nanComplexity = metadata.semanticComplexity(for: nanFloat.bitPattern64)
            #expect(nanComplexity == UInt64.max)
            
            // Test infinity
            let infFloat = Float.infinity
            let infComplexity = metadata.semanticComplexity(for: infFloat.bitPattern64)
            #expect(infComplexity == UInt64.max)
            
            // Test very large float
            let largeFloat = Float.greatestFiniteMagnitude
            let largeComplexity = metadata.semanticComplexity(for: largeFloat.bitPattern64)
            #expect(largeComplexity == UInt64.max) // Should clamp to UInt64.max
        }
        
        @Test("Double complexity")
        func testDoubleComplexity() {
            let metadata = ChoiceMetadata(
                validRanges: [0...UInt64.max],
                strategies: [.decimal, .minimal]
            )
            
            // Test positive double
            let positiveDouble: Double = 123.456
            let positiveComplexity = metadata.semanticComplexity(for: positiveDouble.bitPattern64)
            #expect(positiveComplexity == 123)
            
            // Test negative double
            let negativeDouble: Double = -123.456
            let negativeComplexity = metadata.semanticComplexity(for: negativeDouble.bitPattern64)
            #expect(negativeComplexity == 123)
            
            // Test zero
            let zeroDouble: Double = 0.0
            let zeroComplexity = metadata.semanticComplexity(for: zeroDouble.bitPattern64)
            #expect(zeroComplexity == 0)
            
            // Test NaN
            let nanDouble = Double.nan
            let nanComplexity = metadata.semanticComplexity(for: nanDouble.bitPattern64)
            #expect(nanComplexity == UInt64.max)
            
            // Test infinity
            let infDouble = Double.infinity
            let infComplexity = metadata.semanticComplexity(for: infDouble.bitPattern64)
            #expect(infComplexity == UInt64.max)
            
            // Test very large double
            let largeDouble = Double.greatestFiniteMagnitude
            let largeComplexity = metadata.semanticComplexity(for: largeDouble.bitPattern64)
            #expect(largeComplexity == UInt64.max) // Should clamp to UInt64.max
        }
        
        @Test("Signed 32-bit integer complexity")
        func testSignedInt32Complexity() {
            let metadata = ChoiceMetadata(
                validRanges: [0...UInt64(UInt32.max)],
                strategies: [.signed, .minimal]
            )
            
            // Test positive int32
            let positiveInt: Int32 = 42
            let positiveComplexity = metadata.semanticComplexity(for: positiveInt.bitPattern64)
            #expect(positiveComplexity == 42)
            
            // Test negative int32
            let negativeInt: Int32 = -42
            let negativeComplexity = metadata.semanticComplexity(for: negativeInt.bitPattern64)
            #expect(negativeComplexity == 42)
            
            // Test zero
            let zeroInt: Int32 = 0
            let zeroComplexity = metadata.semanticComplexity(for: zeroInt.bitPattern64)
            #expect(zeroComplexity == 0)
            
            // Test -1 (important edge case)
            let minusOne: Int32 = -1
            let minusOneComplexity = metadata.semanticComplexity(for: minusOne.bitPattern64)
            #expect(minusOneComplexity == 1)
        }
        
        @Test("Unsigned 32-bit integer complexity")
        func testUnsignedInt32Complexity() {
            let metadata = ChoiceMetadata(
                validRanges: [0...UInt64(UInt32.max)],
                strategies: [.minimal]
            )
            
            // Test regular uint32
            let value: UInt32 = 42
            let complexity = metadata.semanticComplexity(for: value.bitPattern64)
            #expect(complexity == 42)
            
            // Test zero
            let zeroValue: UInt32 = 0
            let zeroComplexity = metadata.semanticComplexity(for: zeroValue.bitPattern64)
            #expect(zeroComplexity == 0)
            
            // Test max value
            let maxValue = UInt32.max
            let maxComplexity = metadata.semanticComplexity(for: maxValue.bitPattern64)
            #expect(maxComplexity == UInt64(UInt32.max))
        }
        
        @Test("Signed 64-bit integer complexity")
        func testSignedInt64Complexity() {
            let metadata = ChoiceMetadata(
                validRanges: [0...UInt64.max],
                strategies: [.signed, .minimal]
            )
            
            // Test positive int64
            let positiveInt: Int64 = 1000
            let positiveComplexity = metadata.semanticComplexity(for: positiveInt.bitPattern64)
            #expect(positiveComplexity == 1000)
            
            // Test negative int64
            let negativeInt: Int64 = -1000
            let negativeComplexity = metadata.semanticComplexity(for: negativeInt.bitPattern64)
            #expect(negativeComplexity == 1000)
            
            // Test zero
            let zeroInt: Int64 = 0
            let zeroComplexity = metadata.semanticComplexity(for: zeroInt.bitPattern64)
            #expect(zeroComplexity == 0)
        }
        
        @Test("Unsigned 64-bit integer complexity")
        func testUnsignedInt64Complexity() {
            let metadata = ChoiceMetadata(
                validRanges: [0...UInt64.max],
                strategies: [.minimal]
            )
            
            // Test regular uint64
            let value: UInt64 = 1000
            let complexity = metadata.semanticComplexity(for: value.bitPattern64)
            #expect(complexity == 1000)
            
            // Test zero
            let zeroValue: UInt64 = 0
            let zeroComplexity = metadata.semanticComplexity(for: zeroValue.bitPattern64)
            #expect(zeroComplexity == 0)
        }
        
        @Test("Arbitrary bit width complexity")
        func testArbitraryBitWidthComplexity() {
            // Test 8-bit signed
            let int8Metadata = ChoiceMetadata(
                validRanges: [0...UInt64(UInt8.max)],
                strategies: [.signed, .minimal]
            )
            
            let positiveInt8: Int8 = 42
            let positiveComplexity = int8Metadata.semanticComplexity(for: positiveInt8.bitPattern64)
            #expect(positiveComplexity == 42)
            
            let negativeInt8: Int8 = -42
            let negativeComplexity = int8Metadata.semanticComplexity(for: negativeInt8.bitPattern64)
            #expect(negativeComplexity == 42)
            
            // Test 16-bit unsigned
            let uint16Metadata = ChoiceMetadata(
                validRanges: [0...UInt64(UInt16.max)],
                strategies: [.minimal]
            )
            
            let uint16Value: UInt16 = 1000
            let uint16Complexity = uint16Metadata.semanticComplexity(for: uint16Value.bitPattern64)
            #expect(uint16Complexity == 1000)
        }
        
        @Test("Edge case with no valid ranges")
        func testNoValidRanges() {
            let metadata = ChoiceMetadata(
                validRanges: [],
                strategies: [.minimal]
            )
            
            let value: UInt64 = 42
            let complexity = metadata.semanticComplexity(for: value)
            #expect(complexity == value) // Should return the raw value
        }
    }
}
