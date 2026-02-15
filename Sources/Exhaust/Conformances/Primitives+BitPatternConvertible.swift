//
//  Primitives+BitPatternConvertible.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Foundation

extension Optional: BitPatternConvertible where Wrapped: BitPatternConvertible {
    public static var tag: TypeTag { Wrapped.tag }
    
    public static var bitPatternRanges: [ClosedRange<UInt64>] {
        Wrapped.bitPatternRanges
    }
    
    public init(bitPattern64: UInt64) {
        self = .some(Wrapped(bitPattern64: bitPattern64))
    }
    
    public var bitPattern64: UInt64 {
        switch self {
        case .none:
            0
        case .some(let wrapped):
            wrapped.bitPattern64
        }
    }
}

extension UInt8: BitPatternConvertible {
    public static var tag: TypeTag { .uint8 }
    
    public init(bitPattern64: UInt64) {
        self = UInt8(truncatingIfNeeded: bitPattern64)
    }
    
    public static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64(UInt8.min)...UInt64(UInt8.max)
        ]
    }
    
    public var bitPattern64: UInt64 {
        UInt64(self)
    }
}

extension UInt16: BitPatternConvertible {
    public static var tag: TypeTag { .uint16 }
    
    public init(bitPattern64: UInt64) {
        self = UInt16(bitPattern64)
    }
    
    public static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64(UInt16.min)...UInt64(UInt16.max)
        ]
    }
    
    public var bitPattern64: UInt64 {
        UInt64(self)
    }
}

extension UInt32: BitPatternConvertible {
    public static var tag: TypeTag { .uint32 }
    
    public init(bitPattern64: UInt64) {
        self = UInt32(bitPattern64)
    }
    
    public static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64(UInt32.min)...UInt64(UInt32.max)
        ]
    }
    
    public var bitPattern64: UInt64 {
        UInt64(self)
    }
}

/// Implemented for bidirectionality
extension UInt64: BitPatternConvertible {
    public static var tag: TypeTag { .uint64 }
    
    public static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64.min...UInt64.max
        ]
    }
    
    public init(bitPattern64: UInt64) {
        self = bitPattern64
    }
    
    public var bitPattern64: UInt64 {
        self
    }
}

extension UInt: BitPatternConvertible {
    public static var tag: TypeTag { .uint }

    public static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64(UInt.min)...UInt64(UInt.max)
        ]
    }
    
    public init(bitPattern64: UInt64) {
        self = UInt(bitPattern64)
    }
    
    public var bitPattern64: UInt64 {
        UInt64(self)
    }
}

extension Int8: BitPatternConvertible {
    public static var tag: TypeTag { .int8 }
    private static let signBitMask: UInt8 = 0x80
    
    public init(bitPattern64: UInt64) {
        self = Int8(Int8(bitPattern: UInt8(truncatingIfNeeded: bitPattern64) ^ Self.signBitMask))
    }
    
    public static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64(UInt8.min)...UInt64(UInt8.max)
        ]
    }
    
    public var bitPattern64: UInt64 {
        return UInt64(UInt8(bitPattern: self) ^ Self.signBitMask)
    }
}

extension Int16: BitPatternConvertible {
    public static var tag: TypeTag { .int16 }
    private static let signBitMask: UInt16 = 0x8000
    
    public init(bitPattern64: UInt64) {
        self = Int16(Int16(bitPattern: UInt16(truncatingIfNeeded: bitPattern64) ^ Self.signBitMask))
    }
    
    public static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64(UInt16.min)...UInt64(UInt16.max)
        ]
    }
    
    public var bitPattern64: UInt64 {
        return UInt64(UInt16(bitPattern: self) ^ Self.signBitMask)
    }
}

extension Int32: BitPatternConvertible {
    public static var tag: TypeTag { .int32 }
    private static let signBitMask: UInt32 = 0x80000000
    
    public init(bitPattern64: UInt64) {
        self = Int32(Int32(bitPattern: UInt32(truncatingIfNeeded: bitPattern64) ^ Self.signBitMask))
    }
    
    public static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64(UInt32.min)...UInt64(UInt32.max)
        ]
    }
    
    public var bitPattern64: UInt64 {
        return UInt64(UInt32(bitPattern: self) ^ Self.signBitMask)
    }
}

extension Int64: BitPatternConvertible {
    public static var tag: TypeTag { .int64 }
    private static let signBitMask: UInt64 = 0x8000000000000000
    
    public init(bitPattern64: UInt64) {
        self = Int64(bitPattern: bitPattern64 ^ Self.signBitMask)
    }
    
    public static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64.min...UInt64.max
        ]
    }
    
    public var bitPattern64: UInt64 {
        return UInt64(bitPattern: self) ^ Self.signBitMask
    }
}

extension Int: BitPatternConvertible {
    public static var tag: TypeTag { .int }
    private static let signBitMask: UInt64 = 0x8000000000000000
    public init(bitPattern64: UInt64) {
        // Map UInt64 directly to Int using bit pattern, which handles the full range safely
        self = Int(Int64(bitPattern: bitPattern64 ^ Self.signBitMask))
    }
    
    /// Maps the full Int range to the full UInt64 range.
    public static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64.min...UInt64.max
        ]
    }
    
    /// Maps Int to UInt64 using bit pattern conversion
    public var bitPattern64: UInt64 {
        // Use bit pattern conversion which handles the full Int range safely
        return UInt64(bitPattern: Int64(self)) ^ Self.signBitMask
    }
}

extension Float: BitPatternConvertible {
    public static var tag: TypeTag { .float }
    private static let signBitMask: UInt32 = 0x80000000
    
    /// A `Float` can use the entire `UInt32` space for its bit pattern.
    public static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64(UInt32.min)...UInt64(UInt32.max)
        ]
    }
    
    /// Creates a `Float` from a `UInt64` with ordering-preserving encoding.
    public init(bitPattern64: UInt64) {
        let bitPattern32 = UInt32(bitPattern64)
        let rawBitPattern: UInt32
        // Negative numbers were encoded with ~rawBitPattern, so their encoded values have sign bit clear
        // Positive numbers were encoded with rawBitPattern ^ signBitMask, so their encoded values have sign bit set
        if bitPattern32 & Self.signBitMask == 0 {
            // This was a negative number: flip all bits back
            rawBitPattern = ~bitPattern32
        } else {
            // This was a positive number: flip sign bit back
            rawBitPattern = bitPattern32 ^ Self.signBitMask
        }
        self = Float(bitPattern: rawBitPattern)
    }
    
    /// The underlying IEEE 754 bits with ordering-preserving encoding, promoted to a `UInt64`.
    /// Positive numbers have sign bit flipped, negative numbers have all bits flipped.
    /// This ensures that the natural UInt64 ordering matches the Float ordering.
    public var bitPattern64: UInt64 {
        let rawBitPattern = self.bitPattern
        if rawBitPattern & Self.signBitMask == 0 {
            // Positive numbers: flip sign bit
            return UInt64(rawBitPattern ^ Self.signBitMask)
        } else {
            // Negative numbers: flip all bits
            return UInt64(~rawBitPattern)
        }
    }
}

extension Double: BitPatternConvertible {
    public static var tag: TypeTag { .double }
    private static let signBitMask: UInt64 = 0x8000000000000000
    
    /// A `Double` uses the full `UInt64` space for its bit pattern.
    public static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64.min...UInt64.max
        ]
    }
    
    /// Creates a `Double` from a `UInt64` with ordering-preserving encoding.
    public init(bitPattern64: UInt64) {
        let rawBitPattern: UInt64
        // Negative numbers were encoded with ~rawBitPattern, so their encoded values have sign bit clear
        // Positive numbers were encoded with rawBitPattern ^ signBitMask, so their encoded values have sign bit set
        if bitPattern64 & Self.signBitMask == 0 {
            // This was a negative number: flip all bits back
            rawBitPattern = ~bitPattern64
        } else {
            // This was a positive number: flip sign bit back
            rawBitPattern = bitPattern64 ^ Self.signBitMask
        }
        self = Double(bitPattern: rawBitPattern)
    }
    
    /// The underlying IEEE 754 bits with ordering-preserving encoding.
    /// Positive numbers have sign bit flipped, negative numbers have all bits flipped.
    /// This ensures that the natural UInt64 ordering matches the Double ordering.
    public var bitPattern64: UInt64 {
        let rawBitPattern = self.bitPattern
        if rawBitPattern & Self.signBitMask == 0 {
            // Positive numbers: flip sign bit
            return rawBitPattern ^ Self.signBitMask
        } else {
            // Negative numbers: flip all bits
            return ~rawBitPattern
        }
    }
}

extension Unicode.Scalar: BitPatternConvertible {
    public static var tag: TypeTag { .character } // FIXME: Ehrm?
    public static var bitPatternRanges: [ClosedRange<UInt64> ]{
        [
            0x000000...0x00D7FF, // Basic Multilingual Plane before surrogates
            0x00E000...0x10FFFF  // Everything after surrogates up to the max
        ]
    }
    
    public init(bitPattern64: UInt64) {
        self = Unicode.Scalar(UInt32(bitPattern64))!
    }
    
    public var bitPattern64: UInt64 {
        UInt64(self.value)
    }
}

extension Character: BitPatternConvertible {
    public static var tag: TypeTag { .character }
    /// Defines the range for characters.
    public static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            32...126, // The most normal ascii characters
            0...31, // Null bytes, tabs, etc
            0x00007F...0x00D7FF, // Basic Multilingual Plane before surrogates
            0x00E000...0x10FFFF  // Everything after surrogates up to the max
        ]
    }

    /// Creates a `Character` from a `UInt64` by assuming it represents a Unicode scalar value.
    public init(bitPattern64: UInt64) {
        let scalar = Unicode.Scalar(UInt32(bitPattern64))!
        self.init(scalar)
    }

    /// Returns the value of the first Unicode scalar in the character.
    /// Note: This may not roundtrip perfectly for multi-scalar characters.
    public var bitPattern64: UInt64 {
        UInt64(self.unicodeScalars.first!.value)
    }
}
