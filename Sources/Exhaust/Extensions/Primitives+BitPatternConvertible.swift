//
//  Primitives+BitPatternConvertible.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Foundation

extension Optional: BitPatternConvertible where Wrapped: BitPatternConvertible {
    static var bitPatternRanges: [ClosedRange<UInt64>] {
        Wrapped.bitPatternRanges
    }
    
    init(bitPattern64: UInt64) {
        self = .some(Wrapped(bitPattern64: bitPattern64))
    }
    
    var bitPattern64: UInt64 {
        switch self {
        case .none:
            0
        case .some(let wrapped):
            wrapped.bitPattern64
        }
    }
}

extension UInt8: BitPatternConvertible {
    init(bitPattern64: UInt64) {
        self = UInt8(bitPattern64)
    }
    
    static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64(UInt8.min)...UInt64(UInt8.max)
        ]
    }
    
    var bitPattern64: UInt64 {
        UInt64(self)
    }
}

extension UInt16: BitPatternConvertible {
    init(bitPattern64: UInt64) {
        self = UInt16(bitPattern64)
    }
    
    static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64(UInt16.min)...UInt64(UInt16.max)
        ]
    }
    
    var bitPattern64: UInt64 {
        UInt64(self)
    }
}

extension UInt32: BitPatternConvertible {
    init(bitPattern64: UInt64) {
        self = UInt32(bitPattern64)
    }
    
    static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64(UInt32.min)...UInt64(UInt32.max)
        ]
    }
    
    var bitPattern64: UInt64 {
        UInt64(self)
    }
}

/// Implemented for bidirectionality
extension UInt64: BitPatternConvertible {
    static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64.min...UInt64.max
        ]
    }
    
    init(bitPattern64: UInt64) {
        self = bitPattern64
    }
    
    var bitPattern64: UInt64 {
        self
    }
}

extension UInt: BitPatternConvertible {
    static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64(UInt.min)...UInt64(UInt.max)
        ]
    }
    
    init(bitPattern64: UInt64) {
        self = UInt(bitPattern64)
    }
    
    var bitPattern64: UInt64 {
        UInt64(self)
    }
}

extension Int8: BitPatternConvertible {
    private static let signBitMask: UInt8 = 0x80
    
    public init(bitPattern64: UInt64) {
        self = Int8(Int8(bitPattern: UInt8(bitPattern64) ^ Self.signBitMask))
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
    private static let signBitMask: UInt16 = 0x8000
    
    public init(bitPattern64: UInt64) {
        self = Int16(Int16(bitPattern: UInt16(bitPattern64) ^ Self.signBitMask))
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
    private static let signBitMask: UInt32 = 0x80000000
    
    public init(bitPattern64: UInt64) {
        self = Int32(Int32(bitPattern: UInt32(bitPattern64) ^ Self.signBitMask))
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
    private static let signBitMask: UInt32 = 0x80000000
    
    /// A `Float` can use the entire `UInt32` space for its bit pattern.
    public static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64(UInt32.min)...UInt64(UInt32.max)
        ]
    }
    
    /// Creates a `Float` from a `UInt64` by first converting to `UInt32`.
    public init(bitPattern64: UInt64) {
        self = Float(bitPattern: UInt32(bitPattern64) ^ Self.signBitMask)
    }
    
    /// The underlying IEEE 754 bits of the `Float`, promoted to a `UInt64`.
    public var bitPattern64: UInt64 {
        return UInt64(self.bitPattern ^ UInt32(Self.signBitMask))
    }
}

extension Double: BitPatternConvertible {
    private static let signBitMask: UInt64 = 0x8000000000000000
    
    /// A `Double` uses the full `UInt64` space for its bit pattern.
    public static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64.min...UInt64.max
        ]
    }
    
    /// Creates a `Double` from a `UInt64` with sign bit normalization.
    public init(bitPattern64: UInt64) {
        // // self = Int(Int64(bitPattern: bitPattern ^ Self.signBitMask))
        let normalizedBitPattern = bitPattern64 ^ Self.signBitMask
        self = Double(bitPattern: normalizedBitPattern)
    }
    
    /// The underlying IEEE 754 bits of the `Double` with sign bit normalization.
    public var bitPattern64: UInt64 {
        self.bitPattern ^ Self.signBitMask
    }
}

extension Unicode.Scalar: BitPatternConvertible {
    public static var bitPatternRanges: [ClosedRange<UInt64> ]{
        [
            0x000000...0x00D7FF, // Basic Multilingual Plane before surrogates
            0x00E000...0x10FFFF  // Everything after surrogates up to the max
        ]
    }
    
    init(bitPattern64: UInt64) {
        self = Unicode.Scalar(UInt32(bitPattern64))!
    }
    
    var bitPattern64: UInt64 {
        UInt64(self.value)
    }
}

extension Character: BitPatternConvertible {
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
