//
//  ChoiceMetadata.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

/// Metadata attached to ``ChoiceTree/choice`` and ``ChoiceTree/sequence`` nodes, capturing the valid range and whether it was explicitly specified.
public struct ChoiceMetadata: Hashable, Equatable, Sendable {
    /// The valid bit-pattern range for this choice, or `nil` if unconstrained.
    public let validRange: ClosedRange<UInt64>?
    /// Whether the range was explicitly specified by the user (e.g. `.array(length: 1...5)`) rather than derived from size scaling.
    public let isRangeExplicit: Bool

    public init(validRange: ClosedRange<UInt64>?, isRangeExplicit: Bool = false) {
        self.validRange = validRange
        self.isRangeExplicit = isRangeExplicit
    }
}
