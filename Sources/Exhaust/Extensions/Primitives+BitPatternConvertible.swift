//
//  Primitives+BitPatternConvertible.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Foundation

extension UInt8: BitPatternConvertible {
    init(bitPattern: UInt64) {
        self = UInt8(bitPattern)
    }
    
    static var bitPatternRange: ClosedRange<UInt64> {
        UInt64(UInt8.min)...UInt64(UInt8.max)
    }
    
    var bitPattern64: UInt64 {
        UInt64(self)
    }
}

extension UInt16: BitPatternConvertible {
    init(bitPattern: UInt64) {
        self = UInt16(bitPattern)
    }
    
    static var bitPatternRange: ClosedRange<UInt64> {
        UInt64(UInt8.min)...UInt64(UInt8.max)
    }
    
    var bitPattern64: UInt64 {
        UInt64(self)
    }
}

extension UInt32: BitPatternConvertible {
    init(bitPattern: UInt64) {
        self = UInt32(bitPattern)
    }
    
    static var bitPatternRange: ClosedRange<UInt64> {
        UInt64(UInt8.min)...UInt64(UInt8.max)
    }
    
    var bitPattern64: UInt64 {
        UInt64(self)
    }
}

/// Implemented for bidirectionality
extension UInt64: BitPatternConvertible {
    static var bitPatternRange: ClosedRange<UInt64> {
        UInt64.min...UInt64.max
    }
    
    init(bitPattern: UInt64) {
        self = bitPattern
    }
    
    var bitPattern64: UInt64 {
        self
    }
}

extension UInt: BitPatternConvertible {
    static var bitPatternRange: ClosedRange<UInt64> {
        UInt64(UInt.min)...UInt64(UInt.max)
    }
    
    init(bitPattern: UInt64) {
        self = UInt(bitPattern)
    }
    
    var bitPattern64: UInt64 {
        UInt64(self)
    }
}

extension Int: BitPatternConvertible {
    private static let signBitMask: UInt64 = 0x8000000000000000
    public init(bitPattern: UInt64) {
        // Map UInt64 directly to Int using bit pattern, which handles the full range safely
        self = Int(Int64(bitPattern: bitPattern ^ Self.signBitMask))
    }
    
    /// Maps the full Int range to the full UInt64 range.
    public static var bitPatternRange: ClosedRange<UInt64> {
        UInt64.min...UInt64.max
    }
    
    /// Maps Int to UInt64 using bit pattern conversion
    public var bitPattern64: UInt64 {
        // Use bit pattern conversion which handles the full Int range safely
        return UInt64(bitPattern: Int64(self)) ^ Self.signBitMask
    }
}

extension Float: BitPatternConvertible {
    /// A `Float` can use the entire `UInt32` space for its bit pattern.
    /// We can map this to the lower half of the `UInt64` range.
    public static var bitPatternRange: ClosedRange<UInt64> {
        0...UInt64(UInt32.max)
    }
    
    /// Creates a `Float` from a `UInt64` by first converting to `UInt32`.
    public init(bitPattern: UInt64) {
        self.init(bitPattern)
    }
    
    /// The underlying IEEE 754 bits of the `Float`, promoted to a `UInt64`.
    public var bitPattern64: UInt64 {
        return UInt64(self.bitPattern)
    }
}

// You could provide a similar implementation for `Double`.
extension Double: BitPatternConvertible {
    /// A `Double` uses the full `UInt64` space for its bit pattern.
    public static var bitPatternRange: ClosedRange<UInt64> { 0...UInt64.max }
    
    // `init(bitPattern:)` is provided by Swift's standard library.
    // `var bitPattern: UInt64` is also provided by Swift's standard library.
    var bitPattern64: UInt64 {
        self.bitPattern
    }
}

extension Unicode.Scalar: BitPatternConvertible {
    public static var bitPatternRange: ClosedRange<UInt64> {
        0x000000...0x00D7FF // Basic Multilingual Plane before surrogates
    }
    
    init(bitPattern: UInt64) {
        self = Unicode.Scalar(UInt32(bitPattern))!
    }
    
    var bitPattern64: UInt64 {
        UInt64(self.value)
    }
}

extension Character: BitPatternConvertible {
    /// Defines the range for standard ASCII characters.
    public static var bitPatternRange: ClosedRange<UInt64> {
        0x000000...0x00D7FF // Basic Multilingual Plane before surrogates
    }

    /// Creates a `Character` from a `UInt64` by assuming it represents a Unicode scalar value.
    public init(bitPattern: UInt64) {
        let scalar = Unicode.Scalar(UInt32(bitPattern))!
        self.init(scalar)
    }

    /// Returns the value of the first Unicode scalar in the character.
    /// Note: This may not roundtrip perfectly for multi-scalar characters.
    public var bitPattern64: UInt64 {
        UInt64(self.unicodeScalars.first!.value)
    }
}
