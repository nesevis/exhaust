//
//  Choice.swift
//  Exhaust
//
//  Created by Chris Kolbu on 20/7/2025.
//

enum ChoiceValue: Comparable, Hashable, Equatable {
    case unsigned(UInt64)
    case signed(UInt64, UInt64)
    case floating(UInt64, UInt64)
    case character(Character)

    // Make shrinkable?
    init(_ value: any BitPatternConvertible) {
        switch value {
        case is Double, is Float:
            self = .floating(value.bitPattern64, type(of: value).bitPatternRange.upperBound)
        case is Int64, is Int32, is Int16, is Int8, is Int:
            self = .signed(value.bitPattern64, type(of: value).bitPatternRange.upperBound)
        case is Character:
            self = .character(value as! Character)
        default:
            self = .unsigned(value.bitPattern64)
        }
    }
    
    var complexity: UInt64 {
        switch self {
        case let .unsigned(value):
            return value
        case let .signed(value, mask):
            // Skip denormalization step and work directly with the normalized value
            // Since we know the pattern, we can compute complexity more directly
            let bitWidth = 64 - mask.leadingZeroBitCount
            let signBit = UInt64(1) << (bitWidth - 1)
            
            // The normalized value has the sign bit flipped, so we can detect
            // the original sign by checking if value >= signBit
            if value >= signBit {
                // Originally positive
                return value - signBit
            } else {
                // Originally negative  
                return signBit - value
            }
        case let .floating(value, mask):
            // Determine if this is Float or Double based on mask
            if mask == UInt64(UInt32.max) {
                // Float case - work with 32-bit IEEE 754 format
                let floatBits = UInt32(value)
                let exponent = (floatBits >> 23) & 0xFF
                
                // Check for special values (NaN or infinity)
                if exponent == 0xFF {
                    return UInt64.max
                }
                
                // For normal complexity calculation, convert to float and take floor of abs
                let floatValue = Float(bitPattern: floatBits)
                let absValue = abs(floatValue)
                if absValue >= Float(UInt64.max) {
                    return UInt64.max
                }
                return UInt64(absValue)
            } else {
                // Double case - work with 64-bit IEEE 754 format
                let exponent = (value >> 52) & 0x7FF
                
                // Check for special values (NaN or infinity)
                if exponent == 0x7FF {
                    return UInt64.max
                }
                
                // For normal complexity calculation, convert to double and take floor of abs
                let doubleValue = Double(bitPattern: value)
                let absValue = abs(doubleValue)
                if absValue >= Double(UInt64.max) {
                    return UInt64.max
                }
                return UInt64(absValue)
            }
        case let .character(character):
            return character.bitPattern64
        }
    }

    // This is wrong now
    var convertible: any BitPatternConvertible {
        switch self {
        case .unsigned(let uInt64):
            return uInt64
        case .signed(let int64, _):
            return int64
        case .floating(let double, _):
            return double
        case .character(let character):
            return character
        }
    }
}
