//
//  GeneratorError.swift
//  Exhaust
//
//  Created by Chris Kolbu on 4/8/2025.
//

import Foundation

/// Errors thrown during generator interpretation (forward, backward, or replay passes).
public enum GeneratorError: LocalizedError {
    /// The forward interpreter produced a value but failed to build the corresponding ``ChoiceTree``.
    case choiceTreeConstructionFailed
    /// A generic type mismatch during interpretation.
    case typeMismatch(expected: String, actual: String)
    /// A filter's validity condition was too sparse for the generator to satisfy within its retry budget.
    case sparseValidityCondition
    /// The ``unique`` combinator exhausted its retry budget without finding a new unique value.
    case uniqueBudgetExhausted
    /// A generated sequence requested more elements than ``SharedInterpreterHelpers/maximumSequenceLength``.
    case sequenceLengthExceedsMaximum(length: UInt64, maximum: Int)
    /// A replay seed could not be decoded, or its kind is not supported by the invoking macro.
    case invalidReplaySeed(String)
    /// `#example` was asked for a negative number of values.
    case invalidExampleCount(Int)
    /// Materializing a single value exceeded ``SharedInterpreterHelpers/perValueGenerationBudgetNanoseconds``.
    case generationDeadlineExceeded(seconds: Double)

    public var errorDescription: String? {
        switch self {
            case .choiceTreeConstructionFailed:
                "Generation produced a value but failed to construct the corresponding choice tree."
            case let .typeMismatch(expected, actual):
                "Type mismatch during interpretation: expected '\(expected)', got '\(actual)'."
            case .sparseValidityCondition:
                "The filter predicate rejected too many candidates within the retry budget."
            case .uniqueBudgetExhausted:
                "The unique combinator could not find a new distinct value within its retry budget."
            case let .sequenceLengthExceedsMaximum(length, maximum):
                "A generated sequence requested \(length) elements, exceeding the maximum of \(maximum)."
            case let .invalidReplaySeed(reason):
                "Invalid replay seed: \(reason)."
            case let .invalidExampleCount(count):
                "#example count must be non-negative; got \(count)."
            case let .generationDeadlineExceeded(seconds):
                "Generating a single value exceeded the \(Int(seconds))-second deadline. The generator is intractably large or expensive to run."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
            case .choiceTreeConstructionFailed:
                "This likely indicates a generator composition issue. Check that sub-generators return non-nil values for the current choice sequence."
            case .typeMismatch:
                "This likely indicates a generator composition issue. Verify that map, bind, and contramap closures produce values of the declared type."
            case .sparseValidityCondition:
                "Widen the input generator's range, relax the filter predicate, or increase the filter budget."
            case .uniqueBudgetExhausted:
                "Reduce the number of unique values requested, widen the generator's domain, or increase the retry budget."
            case .sequenceLengthExceedsMaximum:
                "Narrow the length range passed to `arrayOf(within:)` (or the sequence's length generator); a sequence this long is not tractable to generate."
            case .invalidReplaySeed:
                "Copy the seed exactly as printed in the failure report, or pass a raw numeric seed."
            case .invalidExampleCount:
                "Pass zero or a positive count."
            case .generationDeadlineExceeded:
                "Narrow the sequence length ranges (nested sequences multiply: an array of arrays generates rows times columns elements), or simplify expensive map and filter stages."
        }
    }
}
