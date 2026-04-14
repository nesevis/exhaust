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
    /// A value that has been set to its semantically simplest form and should not be individually reduced further.
    case reduced(Value)
    /// Bind scope markers (`true` = open, `false` = close).
    /// The first child is the inner subtree; the second is the bound subtree.
    case bind(Bool)
    /// A marker for a `.just` node. Carries no data but makes `.just` elements visible in the flat sequence (needed for element counting in ``GuidedMaterializer``).
    case just

    @inline(__always)
    public var value: Value? {
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
        case (.group(false), .group(true)),
             (.sequence(false, isLengthExplicit: _), .sequence(true, isLengthExplicit: _)),
             (.bind(false), .bind(true)):
            return .lt
        case (.group(true), .group(false)),
             (.sequence(true, isLengthExplicit: _), .sequence(false, isLengthExplicit: _)),
             (.bind(true), .bind(false)):
            return .gt
        case (.just, .value), (.just, .reduced):
            return .lt
        case (.value, .just), (.reduced, .just):
            return .gt
        case let (.value(a), .value(b)),
             let (.reduced(a), .reduced(b)),
             let (.value(a), .reduced(b)),
             let (.reduced(a), .value(b)):
            return a.shortLexCompare(b)
        default:
            return .eq
        }
    }

    public var shortString: String {
        switch self {
        case .just:
            return "J"
        case .group(true):
            return "("
        case .group(false):
            return ")"
        case .bind(true):
            return "{"
        case .bind(false):
            return "}"
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
        /// Identifies the pick site. Used by the guided cursor to match branch entries to the correct pick operation when cursor positions drift due to bind re-derivation.
        public let fingerprint: UInt64

        public init(id: UInt64, validIDs: [UInt64], fingerprint: UInt64 = 0) {
            self.id = id
            self.validIDs = validIDs
            self.fingerprint = fingerprint
        }
    }

    /// A numeric value entry carrying the ``ChoiceValue``, its valid range, and whether the range was explicitly specified.
    public struct Value: Hashable, Sendable {
        public let choice: ChoiceValue
        public let validRange: ClosedRange<UInt64>?
        public let isRangeExplicit: Bool

        public init(
            choice: ChoiceValue,
            validRange: ClosedRange<UInt64>?,
            isRangeExplicit: Bool = false
        ) {
            self.choice = choice
            self.validRange = validRange
            self.isRangeExplicit = isRangeExplicit
        }

        public func shortLexCompare(_ other: Value) -> ShortlexOrder {
            let lhs = choice.shortlexKey
            let rhs = other.choice.shortlexKey
            if lhs < rhs { return .lt }
            if lhs > rhs { return .gt }
            // Tiebreak: prefer smaller bit pattern (non-negative for same-magnitude floats)
            if choice.bitPattern64 < other.choice.bitPattern64 { return .lt }
            if choice.bitPattern64 > other.choice.bitPattern64 { return .gt }
            return .eq
        }

        /// Whether modular bit-pattern arithmetic on this value stays within the user's declared domain without encoder-level range validation.
        ///
        /// True when the range is size-derived (``isRangeExplicit`` is `false` — the user's real domain is the natural type range and the materializer's clamp at ``Materializer`` handles any narrowing) or when an explicit range equals the natural type range. False when an explicit narrow range is in effect — the encoder must validate each candidate against ``validRange``.
        public var allowsModularArithmetic: Bool {
            if isRangeExplicit == false { return true }
            guard let validRange else { return true }
            return validRange == choice.tag.bitPatternRange
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(choice)
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.choice == rhs.choice
        }
    }
}
