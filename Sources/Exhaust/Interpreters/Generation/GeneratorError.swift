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
    
    var errorDescription: String {
        switch self {
        case .couldNotGenerateConcomitantChoiceTree:
            "Could not generate concomitant choice tree"
        case .mappedBackwardError(let expected, let actual):
            "Mapped backward error: expected \(expected), got \(actual)"
        case .liftFTypeMismatch(let expected, let actual):
            "LiftF type mismatch: expected \(expected), got \(actual)"
        case .typeMismatch(let expected, let actual):
            "Type mismatch: expected \(expected), got \(actual)"
        case .sparseValidityCondition:
            "Sparse validity condition"
        }
        
    }
}
