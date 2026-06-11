//
//  ChoiceMetadata.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

/// Metadata attached to ``ChoiceTree/choice`` and ``ChoiceTree/sequence`` nodes, capturing the valid range and whether it was explicitly specified.
@usableFromInline
package struct ChoiceMetadata: Hashable, Equatable, Sendable {
    /// The valid bit-pattern range for this choice, or `nil` if unconstrained.
    package let validRange: ClosedRange<UInt64>?
    /// Whether the range was explicitly specified by the user (for example `.array(length: 1...5)`) rather than derived from size scaling.
    package let isRangeExplicit: Bool
    /// Per-generator payload for ``TypeTag`` cases that carry analysis-relevant metadata (date parameters, character problematic indices). Nil for all other tag types. Lives here rather than on ``TypeTag`` so that the flat ``ChoiceSequence`` (which carries ``TypeTag`` in every entry) stays compact.
    package let typeTagPayload: TypeTagPayload?

    /// Creates metadata with the given valid range and explicitness flag.
    package init(validRange: ClosedRange<UInt64>?, isRangeExplicit: Bool = false, typeTagPayload: TypeTagPayload? = nil) {
        self.validRange = validRange
        self.isRangeExplicit = isRangeExplicit
        self.typeTagPayload = typeTagPayload
    }
}
