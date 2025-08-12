//
//  TypeTag.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/8/2025.
//

public enum TypeTag: Equatable {
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
