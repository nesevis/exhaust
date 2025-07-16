//
//  Primitives+BitPatternConvertible.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Foundation

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

extension Int: BitPatternConvertible {
    public init(bitPattern: UInt64) {
        self = Int(bitPattern: UInt(bitPattern))
    }
    
    /// Defines the range of `Int` values that can be safely represented by `UInt64`.
    ///
    /// For simplicity, this implementation only considers non-negative integers. A more
    /// advanced implementation could use the full `UInt64` range and handle two's
    // complement for negative numbers, but that significantly complicates the logic.
    public static var bitPatternRange: ClosedRange<UInt64> {
        0...UInt64(bitPattern: Int64.max) // Safest cross-platform range
    }
    
    // Swift provides `init(bitPattern: UInt64)` for Int when the bit widths match
    // or when converting from a smaller integer type. This conformance relies on that.
    
    /// The `UInt64` representation of this `Int`.
    public var bitPattern64: UInt64 {
        // This assumes the Int is non-negative, consistent with `bitPatternRange`.
        return UInt64(self)
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
        // Assumes the bit pattern fits within a UInt32, consistent with the range.
        let bitPattern32 = UInt32(truncatingIfNeeded: bitPattern)
        self.init(bitPattern: bitPattern32)
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

extension Character: BitPatternConvertible {
    /// Defines the range for standard ASCII characters.
    public static var bitPatternRange: ClosedRange<UInt64> {
        0x000000...0x00D7FF // Basic Multilingual Plane before surrogates
    }

    /// Creates a `Character` from a `UInt64` by assuming it represents an ASCII value.
    public init(bitPattern: UInt64) {
        self.init(Unicode.Scalar(UInt32(bitPattern))!)
    }

    /// The ASCII value of the `Character`, promoted to `UInt64`.
    /// This property will be `nil` for non-ASCII characters, so a production implementation
    /// would need to be more robust or use `unicodeScalars` for a wider range.
    public var bitPattern64: UInt64 {
        guard let scalarValue = self.unicodeScalars.first?.value else {
            return 0 // Return a default for empty or invalid characters.
        }
        
        return UInt64(scalarValue)
    }
}
