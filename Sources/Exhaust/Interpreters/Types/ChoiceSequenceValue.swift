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
    
    public var isValue: Bool {
        switch self {
        case .value: return true
        case .group: return false
        case .sequence: return false
        case .branch: return false
        }
    }
    
    
    
    // MARK: - Shortlex
    
    public func shortLexCompare(_ other: ChoiceSequenceValue) -> ShortlexOrder {
        switch (self, other) {
        case (.group(true), .group(true)), (.sequence(true), .sequence(true)):
            return .eq
        case (.group(false), .group(true)), (.sequence(false), .sequence(true)):
            return .lt
        case (.group(true), .group(false)), (.sequence(true), .sequence(false)):
            return .gt
        case (.branch(let a), .branch(let b)), (.value(let a), .value(let b)):
            return a.shortLexCompare(b)
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
            switch (self.choice, other.choice) {
            case let (.unsigned(lhs), .unsigned(rhs)):
                if lhs != rhs { return lhs < rhs ? .lt : .gt }
                return .eq
            case let (.signed(lhs, _, _), .signed(rhs, _, _)):
                if lhs != rhs { return lhs < rhs ? .lt : .gt }
                return .eq
            case let (.floating(lhs, _, _), .floating(rhs, _, _)):
                if lhs != rhs { return lhs < rhs ? .lt : .gt }
                return .eq
            case let (.character(lhs), .character(rhs)):
                if lhs != rhs { return lhs < rhs ? .lt : .gt }
                return .eq
            default:
                // This won't work well when comparing floats
                if self.choice.bitPattern64 != other.choice.bitPattern64 {
                    return self.choice.bitPattern64 < other.choice.bitPattern64 ? .lt : .gt
                }
                return .eq
            }
        }
    }
}
