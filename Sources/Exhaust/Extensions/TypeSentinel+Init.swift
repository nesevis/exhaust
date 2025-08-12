//
//  TypeSentinel+Init.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/8/2025.
//

extension ChoiceValue.TypeSentinel {
    /// Throws a fatal error if initialised with an incompatible type
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
            case is Character.Type:
                    .character // This is handled by `chooseCharacter`
            default:
                fatalError("Unexpected type passed to \(#function): \(T.self)")
            }
    }
}
