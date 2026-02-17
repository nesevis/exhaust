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
    case character

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
        // This case is explicitly handled by `chooseCharacter`, so is unlikely to be used here
        case is Character.Type:
            .character
        default:
            fatalError("Unexpected type passed to \(#function): \(T.self)")
        }
    }
}

extension TypeTag {
    /// Creates a ``BitPatternConvertible`` value from a raw bit pattern using this tag's type.
    func makeConvertible(bitPattern64: UInt64) -> any BitPatternConvertible {
        switch self {
        case .uint: return UInt(bitPattern64: bitPattern64)
        case .uint64: return UInt64(bitPattern64: bitPattern64)
        case .uint32: return UInt32(bitPattern64: bitPattern64)
        case .uint16: return UInt16(bitPattern64: bitPattern64)
        case .uint8: return UInt8(bitPattern64: bitPattern64)
        case .int: return Int(bitPattern64: bitPattern64)
        case .int64: return Int64(bitPattern64: bitPattern64)
        case .int32: return Int32(bitPattern64: bitPattern64)
        case .int16: return Int16(bitPattern64: bitPattern64)
        case .int8: return Int8(bitPattern64: bitPattern64)
        case .double: return Double(bitPattern64: bitPattern64)
        case .float: return Float(bitPattern64: bitPattern64)
        case .character: return Character(bitPattern64: bitPattern64)
        }
    }
}

extension TypeTag: CustomStringConvertible {
    public var description: String {
        switch self {
        case .uint: return "UInt"
        case .uint64: return "UInt64"
        case .uint32: return "UInt32"
        case .uint16: return "UInt16"
        case .uint8: return "UInt8"
        case .int: return "Int"
        case .int64: return "Int64"
        case .int32: return "Int32"
        case .int16: return "Int16"
        case .int8: return "Int8"
        case .double: return "Double"
        case .float: return "Float"
        case .character: return "Character"
        }
    }
}
