//
//  TypeTag.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/8/2025.
//

public enum TypeTag: Equatable, Hashable {
    case uint
    case uint64
    case uint32
    case uint16
    case uint8
    case int
    case int64
    case int32
    case int16
    case int8
    case double
    case float

    @inlinable
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

extension TypeTag {
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
        }
    }
}
