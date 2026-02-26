//
//  FloatingPoint+BitPatternConvertible.swift
//  Exhaust
//
//  Created by Chris Kolbu on 15/2/2026.
//

extension Float: BitPatternConvertible {
    public static var tag: TypeTag {
        .float
    }

    public static var defaultScaling: SizeScaling<Self> { .exponentialFrom(origin: 0) }

    private static let signBitMask: UInt32 = 0x8000_0000

    /// A `Float` can use the entire `UInt32` space for its bit pattern.
    public static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64(UInt32.min) ... UInt64(UInt32.max),
        ]
    }

    /// Creates a `Float` from a `UInt64` with ordering-preserving encoding.
    public init(bitPattern64: UInt64) {
        let bitPattern32 = UInt32(bitPattern64)
        let rawBitPattern: UInt32
            // Negative numbers were encoded with ~rawBitPattern, so their encoded values have sign bit clear
            // Positive numbers were encoded with rawBitPattern ^ signBitMask, so their encoded values have sign bit set
            = if bitPattern32 & Self.signBitMask == 0
        {
            // This was a negative number: flip all bits back
            ~bitPattern32
        } else {
            // This was a positive number: flip sign bit back
            bitPattern32 ^ Self.signBitMask
        }
        self = Float(bitPattern: rawBitPattern)
    }

    /// The underlying IEEE 754 bits with ordering-preserving encoding, promoted to a `UInt64`.
    /// Positive numbers have sign bit flipped, negative numbers have all bits flipped.
    /// This ensures that the natural UInt64 ordering matches the Float ordering.
    public var bitPattern64: UInt64 {
        let rawBitPattern = bitPattern
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
    public static var tag: TypeTag {
        .double
    }

    public static var defaultScaling: SizeScaling<Self> { .exponentialFrom(origin: 0) }

    private static let signBitMask: UInt64 = 0x8000_0000_0000_0000

    /// A `Double` uses the full `UInt64` space for its bit pattern.
    public static var bitPatternRanges: [ClosedRange<UInt64>] {
        [
            UInt64.min ... UInt64.max,
        ]
    }

    /// Creates a `Double` from a `UInt64` with ordering-preserving encoding.
    public init(bitPattern64: UInt64) {
        let rawBitPattern: UInt64
            // Negative numbers were encoded with ~rawBitPattern, so their encoded values have sign bit clear
            // Positive numbers were encoded with rawBitPattern ^ signBitMask, so their encoded values have sign bit set
            = if bitPattern64 & Self.signBitMask == 0
        {
            // This was a negative number: flip all bits back
            ~bitPattern64
        } else {
            // This was a positive number: flip sign bit back
            bitPattern64 ^ Self.signBitMask
        }
        self = Double(bitPattern: rawBitPattern)
    }

    /// The underlying IEEE 754 bits with ordering-preserving encoding.
    /// Positive numbers have sign bit flipped, negative numbers have all bits flipped.
    /// This ensures that the natural UInt64 ordering matches the Double ordering.
    public var bitPattern64: UInt64 {
        let rawBitPattern = bitPattern
        if rawBitPattern & Self.signBitMask == 0 {
            // Positive numbers: flip sign bit
            return rawBitPattern ^ Self.signBitMask
        } else {
            // Negative numbers: flip all bits
            return ~rawBitPattern
        }
    }
}
