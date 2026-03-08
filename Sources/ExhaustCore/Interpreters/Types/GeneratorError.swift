//
//  GeneratorError.swift
//  Exhaust
//
//  Created by Chris Kolbu on 4/8/2025.
//

import Foundation

/// Errors thrown during generator interpretation (forward, backward, or replay passes).
public enum GeneratorError: LocalizedError {
    /// The forward interpreter failed to produce a ``ChoiceTree`` alongside the generated value.
    case couldNotGenerateConcomitantChoiceTree
    /// The backward (reflection) interpreter received a value whose type did not match the expected generator output.
    case mappedBackwardError(expected: String, actual: String)
    /// A `liftF` operation encountered a type mismatch between the expected and actual ``ReflectiveOperation`` payload.
    case liftFTypeMismatch(expected: String, actual: String)
    /// A generic type mismatch during interpretation.
    case typeMismatch(expected: String, actual: String)
    /// A filter's validity condition was too sparse for the generator to satisfy within its retry budget.
    case sparseValidityCondition
    /// The ``unique`` combinator exhausted its retry budget without finding a new unique value.
    case uniqueBudgetExhausted

    var errorDescription: String {
        switch self {
        case .couldNotGenerateConcomitantChoiceTree:
            "Could not generate concomitant choice tree"
        case let .mappedBackwardError(expected, actual):
            "Mapped backward error: expected \(expected), got \(actual)"
        case let .liftFTypeMismatch(expected, actual):
            "LiftF type mismatch: expected \(expected), got \(actual)"
        case let .typeMismatch(expected, actual):
            "Type mismatch: expected \(expected), got \(actual)"
        case .sparseValidityCondition:
            "Sparse validity condition"
        case .uniqueBudgetExhausted:
            "Unique combinator exhausted retry budget without finding a new unique value"
        }
    }
}
