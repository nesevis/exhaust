//
//  Primitives+BitPatternConvertible.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

extension Optional: BitPatternConvertible where Wrapped: BitPatternConvertible {
    package static var tag: TypeTag {
        Wrapped.tag
    }

    package static var defaultScaling: SizeScaling<Self> {
        .constant
    }

    package static var bitPatternRange: ClosedRange<UInt64> {
        Wrapped.bitPatternRange
    }

    package init(bitPattern64: UInt64) {
        self = .some(Wrapped(bitPattern64: bitPattern64))
    }

    package var bitPattern64: UInt64 {
        switch self {
        case .none:
            0
        case let .some(wrapped):
            wrapped.bitPattern64
        }
    }
}

extension UInt8: BitPatternConvertible {
    package static var tag: TypeTag {
        .uint8
    }

    package static var defaultScaling: SizeScaling<Self> {
        .exponential
    }

    public init(bitPattern64: UInt64) {
        self = UInt8(truncatingIfNeeded: bitPattern64)
    }

    package static var bitPatternRange: ClosedRange<UInt64> {
        UInt64(UInt8.min) ... UInt64(UInt8.max)
    }

    public var bitPattern64: UInt64 {
        UInt64(self)
    }
}

extension UInt16: BitPatternConvertible {
    package static var tag: TypeTag {
        .uint16
    }

    package static var defaultScaling: SizeScaling<Self> {
        .exponential
    }

    public init(bitPattern64: UInt64) {
        self = UInt16(truncatingIfNeeded: bitPattern64)
    }

    package static var bitPatternRange: ClosedRange<UInt64> {
        UInt64(UInt16.min) ... UInt64(UInt16.max)
    }

    public var bitPattern64: UInt64 {
        UInt64(self)
    }
}

extension UInt32: BitPatternConvertible {
    package static var tag: TypeTag {
        .uint32
    }

    package static var defaultScaling: SizeScaling<Self> {
        .exponential
    }

    public init(bitPattern64: UInt64) {
        self = UInt32(truncatingIfNeeded: bitPattern64)
    }

    package static var bitPatternRange: ClosedRange<UInt64> {
        UInt64(UInt32.min) ... UInt64(UInt32.max)
    }

    public var bitPattern64: UInt64 {
        UInt64(self)
    }
}

/// Implemented for bidirectionality.
extension UInt64: BitPatternConvertible {
    package static var tag: TypeTag {
        .uint64
    }

    package static var defaultScaling: SizeScaling<Self> {
        .exponential
    }

    package static var bitPatternRange: ClosedRange<UInt64> {
        UInt64.min ... UInt64.max
    }

    public init(bitPattern64: UInt64) {
        self = bitPattern64
    }

    public var bitPattern64: UInt64 {
        self
    }
}

extension UInt: BitPatternConvertible {
    package static var tag: TypeTag {
        .uint
    }

    package static var defaultScaling: SizeScaling<Self> {
        .exponential
    }

    package static var bitPatternRange: ClosedRange<UInt64> {
        UInt64.min ... UInt64.max
    }

    public init(bitPattern64: UInt64) {
        self = UInt(bitPattern64)
    }

    public var bitPattern64: UInt64 {
        UInt64(self)
    }
}

extension Int8: BitPatternConvertible {
    package static var tag: TypeTag {
        .int8
    }

    package static var defaultScaling: SizeScaling<Self> {
        .exponential
    }

    private static let signBitMask: UInt8 = 0x80

    public init(bitPattern64: UInt64) {
        self = Int8(Int8(bitPattern: UInt8(truncatingIfNeeded: bitPattern64) ^ Self.signBitMask))
    }

    package static var bitPatternRange: ClosedRange<UInt64> {
        UInt64(UInt8.min) ... UInt64(UInt8.max)
    }

    public var bitPattern64: UInt64 {
        UInt64(UInt8(bitPattern: self) ^ Self.signBitMask)
    }
}

extension Int16: BitPatternConvertible {
    package static var tag: TypeTag {
        .int16
    }

    package static var defaultScaling: SizeScaling<Self> {
        .exponential
    }

    private static let signBitMask: UInt16 = 0x8000

    public init(bitPattern64: UInt64) {
        self = Int16(Int16(bitPattern: UInt16(truncatingIfNeeded: bitPattern64) ^ Self.signBitMask))
    }

    package static var bitPatternRange: ClosedRange<UInt64> {
        UInt64(UInt16.min) ... UInt64(UInt16.max)
    }

    public var bitPattern64: UInt64 {
        UInt64(UInt16(bitPattern: self) ^ Self.signBitMask)
    }
}

extension Int32: BitPatternConvertible {
    package static var tag: TypeTag {
        .int32
    }

    package static var defaultScaling: SizeScaling<Self> {
        .exponential
    }

    private static let signBitMask: UInt32 = 0x8000_0000

    public init(bitPattern64: UInt64) {
        self = Int32(Int32(bitPattern: UInt32(truncatingIfNeeded: bitPattern64) ^ Self.signBitMask))
    }

    package static var bitPatternRange: ClosedRange<UInt64> {
        UInt64(UInt32.min) ... UInt64(UInt32.max)
    }

    public var bitPattern64: UInt64 {
        UInt64(UInt32(bitPattern: self) ^ Self.signBitMask)
    }
}

extension Int64: BitPatternConvertible {
    package static var tag: TypeTag {
        .int64
    }

    package static var defaultScaling: SizeScaling<Self> {
        .exponential
    }

    private static let signBitMask: UInt64 = 0x8000_0000_0000_0000

    public init(bitPattern64: UInt64) {
        self = Int64(bitPattern: bitPattern64 ^ Self.signBitMask)
    }

    package static var bitPatternRange: ClosedRange<UInt64> {
        UInt64.min ... UInt64.max
    }

    public var bitPattern64: UInt64 {
        UInt64(bitPattern: self) ^ Self.signBitMask
    }
}

extension Int: BitPatternConvertible {
    package static var tag: TypeTag {
        .int
    }

    package static var defaultScaling: SizeScaling<Self> {
        .exponential
    }

    private static let signBitMask: UInt64 = 0x8000_0000_0000_0000
    public init(bitPattern64: UInt64) {
        // Map UInt64 directly to Int using bit pattern, which handles the full range safely
        self = Int(Int64(bitPattern: bitPattern64 ^ Self.signBitMask))
    }

    /// Maps the full Int range to the full UInt64 range.
    package static var bitPatternRange: ClosedRange<UInt64> {
        UInt64.min ... UInt64.max
    }

    /// Maps `Int` to `UInt64` using bit pattern conversion.
    public var bitPattern64: UInt64 {
        // Use bit pattern conversion which handles the full Int range safely
        UInt64(bitPattern: Int64(self)) ^ Self.signBitMask
    }
}
