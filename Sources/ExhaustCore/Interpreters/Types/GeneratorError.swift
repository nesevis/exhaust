//
//  GeneratorError.swift
//  Exhaust
//
//  Created by Chris Kolbu on 4/8/2025.
//

import Foundation

public enum GeneratorError: LocalizedError {
    case couldNotGenerateConcomitantChoiceTree
    case mappedBackwardError(expected: String, actual: String)
    case liftFTypeMismatch(expected: String, actual: String)
    case typeMismatch(expected: String, actual: String)
    case sparseValidityCondition
    case uniqueBudgetExhausted
    case derivativeTypeMismatch

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
        case .derivativeTypeMismatch:
            "Derivative produced a value whose type does not match FinalOutput (e.g. element vs collection)"
        }
    }
}
