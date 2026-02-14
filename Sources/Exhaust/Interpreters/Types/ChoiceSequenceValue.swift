//
//  ChoiceSequenceValue.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation

public enum ChoiceSequenceValue: Hashable, Equatable, Sendable {
    /// The elements within the `true`---`false` range are logically grouped
    case group(Bool)
    /// Values that repeat within a sequence
    /// The elements within the `true`---`false` range are elements of the sequence
    case sequence(Bool)
    /// A marker for a branching choice.
    /// The `Value` contains the chosen index in the array
    /// This marker has no explicit closing marker
    case branch(Value)
    /// Individual values
    case value(Value)
    /// A value that has been set to its semantically simplest form that should not be individually shrunk further
    case reduced(Value)
    
    // MARK: - Shortlex
    
    public func shortLexCompare(_ other: ChoiceSequenceValue) -> ShortlexOrder {
        switch (self, other) {
        case (.group(true), .group(true)), (.sequence(true), .sequence(true)):
            return .eq
        case (.group(false), .group(true)), (.sequence(false), .sequence(true)):
            return .lt
        case (.group(true), .group(false)), (.sequence(true), .sequence(false)):
            return .gt
        case (.branch(let a), .branch(let b)), (.value(let a), .value(let b)), (.reduced(let a), .reduced(let b)):
            return a.shortLexCompare(b)
        case (.reduced, .value):
            return .lt
        default:
            if self.kindOrder < other.kindOrder { return .lt }
            if self.kindOrder > other.kindOrder { return .gt }
            return .eq
        }
    }
    
    /// Canonical ordering of entry kinds for cross-kind comparison.
    private var kindOrder: Int {
        switch self {
        case .group:    return 0
        case .sequence: return 1
        case .branch:   return 2
        case .value:    return 3
        case .reduced:  return 3
        }
    }
    
    var shortString: String {
        switch self {
        case .group(true):
            return "("
        case .group(false):
            return ")"
        case .sequence(true):
            return "["
        case .sequence(false):
            return "]"
        case .value:
            return "V"
        case .reduced:
            return "_"
        case let .branch(value):
            return "B\(value.choice.convertible):"
        }
    }
    
    // MARK: - Inner type
    
    public struct Value: Hashable, Equatable, Sendable {
        let choice: ChoiceValue
        let validRanges: [ClosedRange<UInt64>]

        public init(choice: ChoiceValue, validRanges: [ClosedRange<UInt64>]) {
            self.choice = choice
            self.validRanges = validRanges
        }

        func shortLexCompare(_ other: Value) -> ShortlexOrder {
            let lhs = self.choice.shortlexKey
            let rhs = other.choice.shortlexKey
            if lhs < rhs { return .lt }
            if lhs > rhs { return .gt }
            return .eq
        }
    }
}
