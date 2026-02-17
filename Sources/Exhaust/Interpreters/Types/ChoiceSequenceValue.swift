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

    var value: Value? {
        switch self {
        case let .value(value):
            value
        case let .reduced(value):
            value
        default:
            nil
        }
    }

    // MARK: - Shortlex

    public func shortLexCompare(_ other: ChoiceSequenceValue) -> ShortlexOrder {
        switch (self, other) {
        case (.group(true), .group(true)), (.sequence(true), .sequence(true)):
            return .eq
        case (.group(false), .group(false)), (.sequence(false), .sequence(false)):
            return .eq
        case (.group(false), .group(true)), (.sequence(false), .sequence(true)):
            return .lt
        case (.group(true), .group(false)), (.sequence(true), .sequence(false)):
            return .gt
        case let (.branch(a), .branch(b)), let (.value(a), .value(b)), let (.reduced(a), .reduced(b)), let (.value(a), .reduced(b)), let (.reduced(a), .value(b)):
            return a.shortLexCompare(b)
        default:
            if kindOrder < other.kindOrder { return .lt }
            if kindOrder > other.kindOrder { return .gt }
            return .eq
        }
    }

    /// Canonical ordering of entry kinds for cross-kind comparison.
    private var kindOrder: Int {
        switch self {
        case .group: 1
        case .sequence: 2
        case .branch: 3
        case .value: 4
        case .reduced: 4
        }
    }

    var shortString: String {
        switch self {
        case .group(true):
            "("
        case .group(false):
            ")"
        case .sequence(true):
            "["
        case .sequence(false):
            "]"
        case .value:
            "V"
        case .reduced:
            "_"
        case let .branch(value):
            "B\(value.choice.convertible):"
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
            let lhs = choice.shortlexKey
            let rhs = other.choice.shortlexKey
            if lhs < rhs { return .lt }
            if lhs > rhs { return .gt }
            return .eq
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(choice)
        }
    }
}
