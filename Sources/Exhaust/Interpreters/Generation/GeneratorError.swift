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
}
