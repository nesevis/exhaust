//
//  ChoiceMetadata.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

struct ChoiceMetadata: Equatable {
    // `Character` has discontiguous ranges, and `RangeSet` isn't available until the very newest releases
    let validRanges: [ClosedRange<UInt64>]
    let strategies: ShrinkingStrategies
}

extension ChoiceMetadata {
    func semanticComplexity(for value: UInt64) -> UInt64 {
        guard let range = validRanges.first else { return value }
        
        // Denormalize if the type was normalized (signed integers and floats)
        let denormalizedValue: UInt64
        if strategies.contains(.signed) || strategies.contains(.decimal) {
            let bitWidth = 64 - range.upperBound.leadingZeroBitCount
            let signBitMask = UInt64(1) << (bitWidth - 1)
            denormalizedValue = value ^ signBitMask
        } else {
            denormalizedValue = value
        }
        
        // Calculate semantic complexity based on type
        if strategies.contains(.decimal) {
            // Floating point case
            return complexityForFloatingPoint(denormalizedValue, range: range)
        } else if strategies.contains(.signed) {
            // Signed integer case
            return complexityForSignedInteger(denormalizedValue, range: range)
        } else {
            // Unsigned integer case - return value directly
            return denormalizedValue & range.upperBound
        }
    }
    
    private func complexityForFloatingPoint(_ denormalizedValue: UInt64, range: ClosedRange<UInt64>) -> UInt64 {
        switch range.upperBound {
        case UInt64(UInt32.max):
            // Float case
            let floatValue = Float(bitPattern: UInt32(denormalizedValue))
            if floatValue.isNaN || floatValue.isInfinite {
                return UInt64.max
            }
            let absValue = abs(floatValue)
            if absValue >= Float(UInt64.max) {
                return UInt64.max
            }
            return UInt64(absValue)
        case UInt64.max:
            // Double case  
            let doubleValue = Double(bitPattern: denormalizedValue)
            if doubleValue.isNaN || doubleValue.isInfinite {
                return UInt64.max
            }
            let absValue = abs(doubleValue)
            if absValue >= Double(UInt64.max) {
                return UInt64.max
            }
            return UInt64(absValue)
        default:
            // Shouldn't happen for floating point types, but return safe fallback
            return denormalizedValue & range.upperBound
        }
    }
    
    private func complexityForSignedInteger(_ denormalizedValue: UInt64, range: ClosedRange<UInt64>) -> UInt64 {
        let maskedValue = denormalizedValue & range.upperBound
        let bitWidth = 64 - range.upperBound.leadingZeroBitCount
        let signBit = UInt64(1) << (bitWidth - 1)
        
        if maskedValue & signBit != 0 {
            // Negative value - convert to positive magnitude using two's complement
            let magnitude = ((~maskedValue) + 1) & range.upperBound
            
            // Handle overflow cases for minimum values
            if magnitude == signBit {
                // This is the minimum value (e.g., Int64.min, Int32.min)
                return signBit  // Return the magnitude directly
            }
            
            return magnitude
        } else {
            // Positive value
            return maskedValue
        }
    }
}
