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
            let metadata = ChoiceMetadata(validRanges: [], strategies: [])
            
            // Test positive float
            let positiveFloat: Float = 42.5
            let positiveTree = ChoiceTree.choice(ChoiceValue(positiveFloat), metadata)
            #expect(positiveTree.complexity == 42)
            
            // Test negative float
            let negativeFloat: Float = -42.5
            let negativeTree = ChoiceTree.choice(ChoiceValue(negativeFloat), metadata)
            #expect(negativeTree.complexity == 42)
            
            // Test zero
            let zeroFloat: Float = 0.0
            let zeroTree = ChoiceTree.choice(ChoiceValue(zeroFloat), metadata)
            #expect(zeroTree.complexity == 0)
            
            // Test NaN
            let nanFloat = Float.nan
            let nanTree = ChoiceTree.choice(ChoiceValue(nanFloat), metadata)
            #expect(nanTree.complexity == UInt64.max)
            
            // Test infinity
            let infFloat = Float.infinity
            let infTree = ChoiceTree.choice(ChoiceValue(infFloat), metadata)
            #expect(infTree.complexity == UInt64.max)
            
            // Test very large float
            let largeFloat = Float.greatestFiniteMagnitude
            let largeTree = ChoiceTree.choice(ChoiceValue(largeFloat), metadata)
            #expect(largeTree.complexity == UInt64.max) // Should clamp to UInt64.max
        }
        
        @Test("Double complexity")
        func testDoubleComplexity() {
            let metadata = ChoiceMetadata(validRanges: [], strategies: [])
            
            // Test positive double
            let positiveDouble: Double = 123.456
            let positiveTree = ChoiceTree.choice(ChoiceValue(positiveDouble), metadata)
            #expect(positiveTree.complexity == 123)
            
            // Test negative double
            let negativeDouble: Double = -123.456
            let negativeTree = ChoiceTree.choice(ChoiceValue(negativeDouble), metadata)
            #expect(negativeTree.complexity == 123)
            
            // Test zero
            let zeroDouble: Double = 0.0
            let zeroTree = ChoiceTree.choice(ChoiceValue(zeroDouble), metadata)
            #expect(zeroTree.complexity == 0)
            
            // Test NaN
            let nanDouble = Double.nan
            let nanTree = ChoiceTree.choice(ChoiceValue(nanDouble), metadata)
            #expect(nanTree.complexity == UInt64.max)
            
            // Test infinity
            let infDouble = Double.infinity
            let infTree = ChoiceTree.choice(ChoiceValue(infDouble), metadata)
            #expect(infTree.complexity == UInt64.max)
            
            // Test very large double
            let largeDouble = Double.greatestFiniteMagnitude
            let largeTree = ChoiceTree.choice(ChoiceValue(largeDouble), metadata)
            #expect(largeTree.complexity == UInt64.max) // Should clamp to UInt64.max
        }
        
        @Test("Signed 32-bit integer complexity")
        func testSignedInt32Complexity() {
            let metadata = ChoiceMetadata(validRanges: [], strategies: [])
            
            // Test positive int32
            let positiveInt: Int32 = 42
            let positiveTree = ChoiceTree.choice(ChoiceValue(positiveInt), metadata)
            #expect(positiveTree.complexity == 42)
            
            // Test negative int32
            let negativeInt: Int32 = -42
            let negativeTree = ChoiceTree.choice(ChoiceValue(negativeInt), metadata)
            #expect(negativeTree.complexity == 42)
            
            // Test zero
            let zeroInt: Int32 = 0
            let zeroTree = ChoiceTree.choice(ChoiceValue(zeroInt), metadata)
            #expect(zeroTree.complexity == 0)
            
            // Test -1 (important edge case)
            let minusOne: Int32 = -1
            let minusOneTree = ChoiceTree.choice(ChoiceValue(minusOne), metadata)
            #expect(minusOneTree.complexity == 1)
        }
        
        @Test("Unsigned 32-bit integer complexity")
        func testUnsignedInt32Complexity() {
            let metadata = ChoiceMetadata(validRanges: [], strategies: [])
            
            // Test regular uint32
            let value: UInt32 = 42
            let tree = ChoiceTree.choice(ChoiceValue(value), metadata)
            #expect(tree.complexity == 42)
            
            // Test zero
            let zeroValue: UInt32 = 0
            let zeroTree = ChoiceTree.choice(ChoiceValue(zeroValue), metadata)
            #expect(zeroTree.complexity == 0)
            
            // Test max value
            let maxValue = UInt32.max
            let maxTree = ChoiceTree.choice(ChoiceValue(maxValue), metadata)
            #expect(maxTree.complexity == UInt64(UInt32.max))
        }
        
        @Test("Signed 64-bit integer complexity")
        func testSignedInt64Complexity() {
            let metadata = ChoiceMetadata(validRanges: [], strategies: [])
            
            // Test positive int64
            let positiveInt: Int64 = 1000
            let positiveTree = ChoiceTree.choice(ChoiceValue(positiveInt), metadata)
            #expect(positiveTree.complexity == 1000)
            
            // Test negative int64
            let negativeInt: Int64 = -1000
            let negativeTree = ChoiceTree.choice(ChoiceValue(negativeInt), metadata)
            #expect(negativeTree.complexity == 1000)
            
            // Test zero
            let zeroInt: Int64 = 0
            let zeroTree = ChoiceTree.choice(ChoiceValue(zeroInt), metadata)
            #expect(zeroTree.complexity == 0)
        }
        
        @Test("Unsigned 64-bit integer complexity")
        func testUnsignedInt64Complexity() {
            let metadata = ChoiceMetadata(validRanges: [], strategies: [])
            
            // Test regular uint64
            let value: UInt64 = 1000
            let tree = ChoiceTree.choice(ChoiceValue(value), metadata)
            #expect(tree.complexity == 1000)
            
            // Test zero
            let zeroValue: UInt64 = 0
            let zeroTree = ChoiceTree.choice(ChoiceValue(zeroValue), metadata)
            #expect(zeroTree.complexity == 0)
        }
        
        @Test("Arbitrary bit width complexity")
        func testArbitraryBitWidthComplexity() {
            let metadata = ChoiceMetadata(validRanges: [], strategies: [])
            
            // Test 8-bit signed
            let positiveInt8: Int8 = 42
            let positiveTree = ChoiceTree.choice(ChoiceValue(positiveInt8), metadata)
            #expect(positiveTree.complexity == 42)
            
            let negativeInt8: Int8 = -42
            let negativeTree = ChoiceTree.choice(ChoiceValue(negativeInt8), metadata)
            #expect(negativeTree.complexity == 42)
            
            // Test 16-bit unsigned
            let uint16Value: UInt16 = 1000
            let uint16Tree = ChoiceTree.choice(ChoiceValue(uint16Value), metadata)
            #expect(uint16Tree.complexity == 1000)
        }
        
        @Test("ChoiceTree.just complexity")
        func testJustComplexity() {
            // Test that .just cases have zero complexity
            let justTree = ChoiceTree.just("")
            #expect(justTree.complexity == 0)
        }
    }
}
