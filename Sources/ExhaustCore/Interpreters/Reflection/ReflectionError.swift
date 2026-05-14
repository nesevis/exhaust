//
//  ReflectionError.swift
//  Exhaust
//
//  Created by Chris Kolbu on 15/5/2026.
//

import Foundation

/// Errors thrown by the reflection interpreter when a value cannot be mapped back to its choice tree.
public enum ReflectionError: LocalizedError, Equatable {
        /// Indicates that the target value is `nil` but the generator does not produce an optional type.
        case reflectedNil(type: String, resultType: String)
        /// Indicates that the contramap backward function received a value of unexpected type.
        case contramapWasWrongType
        /// Indicates that the zip target has wrong arity or element types for the declared generators.
        case zipWasWrongLengthOrType
        /// Indicates that none of the pick branches could produce a value matching the target.
        case couldNotMapInputToGenerator
        /// Indicates that the target value cannot be encoded as a bit pattern for the declared ``TypeTag``.
        case chooseBitsCouldNotConvertValue(String)
        /// Indicates that the target value for a sequence operation is not a valid collection.
        case inputWasWrongForSequence(String)
        /// Indicates that an individual element within a sequence could not be reflected through the element generator.
        case couldNotReflectOnSequenceElement(String)
        /// Indicates that a pick branch value lacks the ``Equatable`` conformance needed to match against the target.
        case pickValueIsNotEquatable(String)
        /// Indicates that the reflected bit pattern falls outside the declared chooseBits range.
        case inputWasOutOfGeneratorRange(String, range: String)
        /// Reflection failed because a forward-only `map` was detected.
        /// Use `.mapped(forward:backward:)` instead to enable bidirectional operation.
        case forwardOnlyMap(inputType: String, outputType: String)
        /// Reflection failed because a forward-only `bind` was detected.
        case forwardOnlyBind(inputType: String, outputType: String)
        /// Reflection failed because a metamorphic transform was detected.
        /// Metamorph transforms are forward-only and cannot be reflected backward.
        case forwardOnlyMetamorph

        public var errorDescription: String? {
            switch self {
            case let .reflectedNil(type, resultType):
                "Reflection target is nil (type '\(type)'), but the generator produces non-optional '\(resultType)'."
            case .contramapWasWrongType:
                "The contramap backward function received a value of an unexpected type."
            case .zipWasWrongLengthOrType:
                "The zip reflection target has the wrong arity or element types for the declared generators."
            case .couldNotMapInputToGenerator:
                "No pick branch produced a value matching the reflection target."
            case let .chooseBitsCouldNotConvertValue(value):
                "Value '\(value)' cannot be encoded as a bit pattern for the declared type tag."
            case let .inputWasWrongForSequence(detail):
                "The reflection target is not a valid collection for the sequence operation: \(detail)."
            case let .couldNotReflectOnSequenceElement(detail):
                "A sequence element could not be reflected through the element generator: \(detail)."
            case let .pickValueIsNotEquatable(type):
                "Pick branch value of type '\(type)' lacks Equatable conformance required for reflection matching."
            case let .inputWasOutOfGeneratorRange(value, range):
                "Reflected bit pattern for '\(value)' falls outside the declared range \(range)"
            case let .forwardOnlyMap(inputType, outputType):
                "Reflection failed: forward-only map (\(inputType) -> \(outputType)) detected."
            case let .forwardOnlyBind(inputType, outputType):
                "Reflection failed: forward-only bind (\(inputType) -> \(outputType)) detected."
            case .forwardOnlyMetamorph:
                "Reflection failed: metamorphic transforms are forward-only and cannot be reflected."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .reflectedNil:
                "Wrap the generator in .optional() to allow nil values, or ensure the reflection target is non-nil."
            case .contramapWasWrongType:
                "This likely indicates a generator composition issue. Verify that the backward closure's input type matches the generator's output type."
            case .zipWasWrongLengthOrType:
                "This likely indicates a generator composition issue. Verify that the target tuple matches the arity and element types of the zipped generators."
            case .couldNotMapInputToGenerator:
                "Add a pick branch whose value matches the target, or verify the target is within the generator's domain."
            case .chooseBitsCouldNotConvertValue:
                "Ensure the value conforms to the type expected by the generator's TypeTag."
            case .inputWasWrongForSequence:
                "Pass an Array or other supported collection type as the reflection target."
            case .couldNotReflectOnSequenceElement:
                "Ensure every element in the target collection is within the element generator's domain."
            case let .pickValueIsNotEquatable(type):
                "Add Equatable conformance to '\(type)' or use a different generator that does not require value matching."
            case .inputWasOutOfGeneratorRange:
                "Widen the generator's range to include this value, or ensure the reflection target is within bounds."
            case .forwardOnlyMap:
                "Use .mapped(forward:backward:) to supply a backward function for bidirectional reflection."
            case .forwardOnlyBind:
                "Use .bound(forward:backward:) to supply a backward function for bidirectional reflection."
            case .forwardOnlyMetamorph:
                "Metamorphic transforms cannot be reflected. If bidirectional operation is needed, use .mapped(forward:backward:) instead."
            }
        }
    }
