//
//  TypeTag.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/8/2025.
//

/// Identifies the numeric type of a ``ChoiceValue``, used for reconstruction, display, and boundary analysis.
public enum TypeTag: Equatable, Hashable, Sendable {
    /// Platform-width unsigned integer (`UInt`).
    case uint
    /// 64-bit unsigned integer.
    case uint64
    /// 32-bit unsigned integer.
    case uint32
    /// 16-bit unsigned integer.
    case uint16
    /// 8-bit unsigned integer.
    case uint8
    /// Platform-width signed integer (`Int`).
    case int
    /// 64-bit signed integer.
    case int64
    /// 32-bit signed integer.
    case int32
    /// 16-bit signed integer.
    case int16
    /// 8-bit signed integer.
    case int8
    /// Double-precision floating point.
    case double
    /// Single-precision floating point.
    case float
    /// Half-precision floating point (ARM64 only).
    case float16
    /// Date steps: the underlying integer represents step indices, where each step is `intervalSeconds` seconds offset from `lowerSeconds`. Used by boundary analysis to compute calendar-meaningful boundary values (month/year boundaries, DST transitions). The `timeZoneID` limits DST boundary values to a single timezone.
    case date(lowerSeconds: Int64, intervalSeconds: Int64, timeZoneID: String)
    /// Raw bit storage used by composite generators (UUID, Int128, UInt128). Boundary analysis produces only all-low / all-high values.
    case bits

    /// Creates a type tag by matching the metatype of the given value against known numeric types.
    public init<T>(type: T) {
        self = switch type {
        case is Double.Type:
            .double
        case is Int.Type:
            .int
        case is UInt.Type:
            .uint
        // More specific, less likely to be used
        case is Float.Type:
            .float
        case is Int64.Type:
            .int64
        case is Int32.Type:
            .int32
        case is Int16.Type:
            .int16
        case is Int8.Type:
            .int8
        case is UInt64.Type:
            .uint64
        case is UInt32.Type:
            .uint32
        case is UInt16.Type:
            .uint16
        case is UInt8.Type:
            .uint8
        default:
            fatalError("Unexpected type passed to \(#function): \(T.self)")
        }
    }
}

public extension TypeTag {
    /// Whether this tag represents a signed integer type.
    var isSigned: Bool {
        switch self {
        case .int, .int8, .int16, .int32, .int64:
            true
        default:
            false
        }
    }

    /// Whether this tag represents a floating-point type.
    var isFloatingPoint: Bool {
        switch self {
        case .double, .float, .float16:
            true
        default:
            false
        }
    }

    /// The full bit-pattern range reachable by the underlying type.
    ///
    /// Equivalent to `Underlying.bitPatternRange` — bridges the static protocol requirement through this tag's type identity. Used by encoders to detect when a value's declared domain equals the natural type width, enabling modular bit-pattern arithmetic without encoder-level range validation.
    var bitPatternRange: ClosedRange<UInt64> {
        type(of: makeConvertible(bitPattern64: 0)).bitPatternRange
    }

    /// Creates a ``BitPatternConvertible`` value from a raw bit pattern using this tag's type.
    func makeConvertible(bitPattern64: UInt64) -> any BitPatternConvertible {
        switch self {
        case .uint: UInt(bitPattern64: bitPattern64)
        case .uint64: UInt64(bitPattern64: bitPattern64)
        case .uint32: UInt32(bitPattern64: bitPattern64)
        case .uint16: UInt16(bitPattern64: bitPattern64)
        case .uint8: UInt8(bitPattern64: bitPattern64)
        case .int: Int(bitPattern64: bitPattern64)
        case .int64: Int64(bitPattern64: bitPattern64)
        case .int32: Int32(bitPattern64: bitPattern64)
        case .int16: Int16(bitPattern64: bitPattern64)
        case .int8: Int8(bitPattern64: bitPattern64)
        case .double: Double(bitPattern64: bitPattern64)
        case .float: Float(bitPattern64: bitPattern64)
        #if arch(arm64) || arch(arm64_32)
            case .float16: Float16(bitPattern64: bitPattern64)
        #else
            case .float16: Float(Float16Emulation.doubleValue(fromEncoded: bitPattern64))
        #endif
        case .date: Int64(bitPattern64: bitPattern64)
        case .bits: UInt64(bitPattern64: bitPattern64)
        }
    }
}

extension TypeTag: CustomStringConvertible {
    public var description: String {
        switch self {
        case .uint: "UInt"
        case .uint64: "UInt64"
        case .uint32: "UInt32"
        case .uint16: "UInt16"
        case .uint8: "UInt8"
        case .int: "Int"
        case .int64: "Int64"
        case .int32: "Int32"
        case .int16: "Int16"
        case .int8: "Int8"
        case .double: "Double"
        case .float: "Float"
        case .float16: "Float16"
        case .date: "Date"
        case .bits: "Bits"
        }
    }
}
