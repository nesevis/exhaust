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
    /// Whether the choice was sampled by ``ChooseBitsScaling/size``. Screening and coverage analysis skip such choices: the value is the generation size, not a sampled parameter, and enumerating its range would rebuild every size-dependent generator once per level. The reducer treats the choice like any other: `validRange` is the declared range, so the size can move below the value it had at generation.
    ///
    /// Declared before `typeTagPayload` so both flags share the optional range's tail padding and the struct stays within its 32-byte hot-path budget.
    package let isPinnedToSize: Bool
    /// Per-generator payload for ``TypeTag`` cases that carry analysis-relevant metadata (date parameters, character problematic indices). Nil for all other tag types. Lives here rather than on ``TypeTag`` so that the flat ``ChoiceSequence`` (which carries ``TypeTag`` in every entry) stays compact.
    package let typeTagPayload: TypeTagPayload?

    /// Creates metadata with the given valid range and explicitness flag.
    package init(
        validRange: ClosedRange<UInt64>?,
        isRangeExplicit: Bool = false,
        typeTagPayload: TypeTagPayload? = nil,
        isPinnedToSize: Bool = false
    ) {
        self.validRange = validRange
        self.isRangeExplicit = isRangeExplicit
        self.typeTagPayload = typeTagPayload
        self.isPinnedToSize = isPinnedToSize
    }
}
