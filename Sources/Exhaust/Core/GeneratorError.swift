//
//  GeneratorError.swift
//  Exhaust
//
//  Created by Chris Kolbu on 4/8/2025.
//

import Foundation

enum GeneratorError: LocalizedError {
    case couldNotGenerateConcomitantChoiceTree
    case mappedBackwardError(expected: String, actual: String)
    case liftFTypeMismatch(expected: String, actual: String)
}
