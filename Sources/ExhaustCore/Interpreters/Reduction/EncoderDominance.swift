/// 2-cell dominance pruning of dominated encoders within a hom-set.
///
/// Tracks categorical 2-cell dominance (Sepulveda-Jimenez, Def 15.3) across encoder
/// hom-sets. Within each hom-set (encoders sharing the same decoder), the dominance
/// relation defines when a less-aggressive encoder can be skipped because a
/// more-aggressive one has already succeeded. The 2-cell relationships are:
///
/// - **Deletion**: `deleteContainerSpans` or `deleteAlignedSiblingWindows` ⇒ `deleteContainerSpansWithRandomRepair`
/// - **Deletion**: `deleteAlignedSiblingWindows` ⇒ `deleteAlignedSiblingSubsets`
/// - **Deletion**: `productSpaceBatch` ⇒ `productSpaceAdaptive`
/// - **Value minimization**: `zeroValue` ⇒ `binarySearchToSemanticSimplest` ⇒ `binarySearchToRangeMinimum`
/// - **Value minimization**: `zeroValue` or `binarySearchToSemanticSimplest` ⇒ `linearScan`
///
/// The dominance relation is scoped per hom-set: success in one hom-set (for example, deletion)
/// does not affect dominance in another (for example, value minimization). The scheduler resets
/// dominance at leg boundaries where the decoder changes.
///
/// During the covariant depth sweep (structure-preserving), dominance is stable — no
/// structural changes occur. During the deletion sweep, dominance must be invalidated
/// after each success (spans change).
///
/// Reference: Sepulveda-Jimenez, Def 15.3 (2-cell dominance).
struct EncoderDominance {
    /// Encoders that have accepted at least one candidate since the last invalidation.
    private var succeeded: Set<EncoderName> = []

    /// Records that an encoder accepted a candidate.
    @inline(__always)
    mutating func recordSuccess(_ name: EncoderName) {
        succeeded.insert(name)
    }

    /// Clears all success tracking. Called at leg boundaries or after structural changes
    /// that invalidate the span layout.
    @inline(__always)
    mutating func invalidate() {
        succeeded.removeAll()
    }

    /// Returns `true` if the encoder should be skipped because a dominating encoder
    /// has already succeeded within the same hom-set.
    ///
    /// Only checks dominators within the same ``ReductionPhase`` — cross-phase
    /// dominance is not defined (the leg ordering handles inter-phase sequencing).
    func shouldSkip(_ name: EncoderName, phase: ReductionPhase) -> Bool {
        switch (phase, name) {
        // Either guided deletion encoder dominates speculative single-span deletion:
        // both share the same span pool and use a stricter guided decoder.
        case (.structuralDeletion, .deleteContainerSpansWithRandomRepair):
            succeeded.contains(.deleteContainerSpans)
                || succeeded.contains(.deleteAlignedSiblingWindows)
        // Contiguous window deletion dominates beam search subset deletion:
        // every contiguous window is a degenerate non-contiguous subset.
        case (.structuralDeletion, .deleteAlignedSiblingSubsets):
            succeeded.contains(.deleteAlignedSiblingWindows)
        // Direct descendant promotion dominates full cross-group promotion:
        // if collapsing to a direct child made progress, exhaustive search is deferred.
        case (.structuralDeletion, .deleteByPromotingSimplestBranch):
            succeeded.contains(.promoteDirectDescendantBranch)
        // Antichain delta-debugging dominates mutation pool pair enumeration:
        // the antichain's jointly-deletable subset subsumes individual and pair mutations.
        case (.structuralDeletion, .productSpaceAdaptive):
            succeeded.contains(.productSpaceBatch)
        // Zero is the best binary-search-to-semantic-simplest can achieve.
        case (.valueMinimization, .binarySearchToSemanticSimplest):
            succeeded.contains(.zeroValue)
        // Binary-search-to-semantic-simplest finds values ≤ any nonzero target.
        case (.valueMinimization, .binarySearchToRangeMinimum):
            succeeded.contains(.zeroValue)
                || succeeded.contains(.binarySearchToSemanticSimplest)
        // Linear scan covers a bounded subrange that binary search already searched. NOTE: this edge is per-encoder (global), not per-coordinate. LinearScan fires on .nonMonotoneGap signals at specific coordinates where binary search detected non-monotonicity. If binary search succeeded at a DIFFERENT coordinate, this skip suppresses LinearScan at coordinates where it is genuinely needed. Revisit whether this should be per-coordinate or removed entirely.
        case (.valueMinimization, .linearScan):
            succeeded.contains(.zeroValue)
                || succeeded.contains(.binarySearchToSemanticSimplest)
        default:
            false
        }
    }
}
