//
//  ChoiceSequenceValue.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation

@_spi(ExhaustInternal) public enum ChoiceSequenceValue: Hashable, Equatable, Sendable {
    /// The elements within the `true`---`false` range are logically grouped
    case group(Bool)
    /// Values that repeat within a sequence
    /// The elements within the `true`---`false` range are elements of the sequence
    case sequence(Bool, isLengthExplicit: Bool = false)
    /// A marker for a branching choice.
    /// Stores selected branch id and the valid branch ids for the pick site.
    /// This marker has no explicit closing marker.
    case branch(Branch)
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

    @_spi(ExhaustInternal) public func shortLexCompare(_ other: ChoiceSequenceValue) -> ShortlexOrder {
        switch (self, other) {
        case (.group(true), .group(true)), (.sequence(true, isLengthExplicit: _), .sequence(true, isLengthExplicit: _)):
            return .eq
        case (.group(false), .group(false)), (.sequence(false, isLengthExplicit: _), .sequence(false, isLengthExplicit: _)):
            return .eq
        case (.group(false), .group(true)), (.sequence(false, isLengthExplicit: _), .sequence(true, isLengthExplicit: _)):
            return .lt
        case (.group(true), .group(false)), (.sequence(true, isLengthExplicit: _), .sequence(false, isLengthExplicit: _)):
            return .gt
        case let (.branch(a), .branch(b)):
            return a.shortLexCompare(b)
        case let (.value(a), .value(b)), let (.reduced(a), .reduced(b)), let (.value(a), .reduced(b)), let (.reduced(a), .value(b)):
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
            return "("
        case .group(false):
            return ")"
        case .sequence(true, isLengthExplicit: _):
            return "["
        case .sequence(false, isLengthExplicit: _):
            return "]"
        case .value:
            return "V"
        case .reduced:
            return "_"
        case let .branch(value):
            let index = value.validIDs.firstIndex(of: value.id) ?? 0
            return "B\(index):"
        }
    }

    // MARK: - Inner type

    @_spi(ExhaustInternal) public struct Branch: Hashable, Equatable, Sendable {
        @_spi(ExhaustInternal) public let id: UInt64
        @_spi(ExhaustInternal) public let validIDs: [UInt64]

        @_spi(ExhaustInternal) public init(id: UInt64, validIDs: [UInt64]) {
            self.id = id
            self.validIDs = validIDs
        }

        func shortLexCompare(_ other: Branch) -> ShortlexOrder {
            if validIDs == other.validIDs,
               let lhsIndex = validIDs.firstIndex(of: id),
               let rhsIndex = other.validIDs.firstIndex(of: other.id)
            {
                if lhsIndex < rhsIndex { return .lt }
                if lhsIndex > rhsIndex { return .gt }
                return .eq
            }
            if id < other.id { return .lt }
            if id > other.id { return .gt }
            return .eq
        }
    }

    @_spi(ExhaustInternal) public struct Value: Hashable, Equatable, Sendable {
        @_spi(ExhaustInternal) public let choice: ChoiceValue
        @_spi(ExhaustInternal) public let validRanges: [ClosedRange<UInt64>]
        @_spi(ExhaustInternal) public let isRangeExplicit: Bool

        @_spi(ExhaustInternal) public init(choice: ChoiceValue, validRanges: [ClosedRange<UInt64>], isRangeExplicit: Bool = false) {
            self.choice = choice
            self.validRanges = validRanges
            self.isRangeExplicit = isRangeExplicit
        }

        func shortLexCompare(_ other: Value) -> ShortlexOrder {
            let lhs = choice.shortlexKey
            let rhs = other.choice.shortlexKey
            if lhs < rhs { return .lt }
            if lhs > rhs { return .gt }
            return .eq
        }

        @_spi(ExhaustInternal) public func hash(into hasher: inout Hasher) {
            hasher.combine(choice)
        }
    }
}
