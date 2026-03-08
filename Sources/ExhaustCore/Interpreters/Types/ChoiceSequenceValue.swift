//
//  ChoiceSequenceValue.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation

/// An element in a flattened ``ChoiceSequence``, representing one entry from a ``ChoiceTree``.
///
/// Structural markers (``group``, ``sequence``, ``branch``, ``just``) delimit containers and pick sites, while ``value`` and ``reduced`` carry the actual numeric choices.
public enum ChoiceSequenceValue: Hashable, Equatable, Sendable {
    /// The elements within the `true`--`false` range are logically grouped.
    case group(Bool)
    /// The elements within the `true`--`false` range are elements of a sequence.
    case sequence(Bool, isLengthExplicit: Bool = false)
    /// A marker for a branching choice. Stores the selected branch identifier and the valid branch identifiers for the pick site. This marker has no explicit closing marker.
    case branch(Branch)
    /// An individual numeric value.
    case value(Value)
    /// A value that has been set to its semantically simplest form and should not be individually shrunk further.
    case reduced(Value)
    /// A marker for a `.just` node. Carries no data but makes `.just` elements visible in the flat sequence (needed for element counting in ``PrefixMaterializer``).
    case just

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
        case .just: 0
        case .group: 1
        case .sequence: 2
        case .branch: 3
        case .value: 4
        case .reduced: 4
        }
    }

    var shortString: String {
        switch self {
        case .just:
            return "J"
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

    /// A branch marker storing the selected branch identifier and all valid identifiers for a pick site.
    public struct Branch: Hashable, Equatable, Sendable {
        public let id: UInt64
        public let validIDs: [UInt64]

        public init(id: UInt64, validIDs: [UInt64]) {
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

    /// A numeric value entry carrying the ``ChoiceValue``, its valid range, and whether the range was explicitly specified.
    public struct Value: Hashable, Sendable {
        public let choice: ChoiceValue
        public let validRange: ClosedRange<UInt64>?
        public let isRangeExplicit: Bool

        public init(choice: ChoiceValue, validRange: ClosedRange<UInt64>?, isRangeExplicit: Bool = false) {
            self.choice = choice
            self.validRange = validRange
            self.isRangeExplicit = isRangeExplicit
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

        public static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.choice == rhs.choice, lhs.isRangeExplicit == rhs.isRangeExplicit else {
                return false
            }
            // When the range is derived from runtime context (size scaling),
            // it can differ between generation and reflection. Only compare
            // validRange when it was explicitly specified by the user.
            if lhs.isRangeExplicit {
                return lhs.validRange == rhs.validRange
            }
            return true
        }
    }
}
