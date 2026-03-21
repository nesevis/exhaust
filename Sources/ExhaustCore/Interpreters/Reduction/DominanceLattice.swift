/// 2-cell dominance pruning of dominated encoders within a hom-set.
///
/// Tracks categorical 2-cell dominance (Sepulveda-Jimenez, Def 15.3) across encoder
/// hom-sets. Within each hom-set (encoders sharing the same decoder), the dominance
/// relation defines when a less-aggressive encoder can be skipped because a
/// more-aggressive one has already succeeded. The 2-cell relationships are:
///
/// - **Deletion**: `deleteContainerSpans` or `deleteAlignedSiblingWindows` ⇒ `deleteContainerSpansWithRandomRepair`
/// - **Value minimization**: `zeroValue` ⇒ `binarySearchToSemanticSimplest` ⇒ `binarySearchToRangeMinimum`
///
/// The dominance relation is scoped per hom-set: success in one hom-set (for example, deletion)
/// does not affect dominance in another (for example, value minimization). The scheduler resets
/// dominance at leg boundaries where the decoder changes.
///
/// During the contravariant sweep (structure-preserving), dominance is stable — no
/// structural changes occur. During the deletion sweep, dominance must be invalidated
/// after each success (spans change). During the covariant sweep, dominance is stable
/// again.
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
        // Zero is the best binary-search-to-semantic-simplest can achieve.
        case (.valueMinimization, .binarySearchToSemanticSimplest):
            succeeded.contains(.zeroValue)
        // Binary-search-to-semantic-simplest finds values ≤ any nonzero target.
        case (.valueMinimization, .binarySearchToRangeMinimum):
            succeeded.contains(.zeroValue) || succeeded.contains(.binarySearchToSemanticSimplest)
        default:
            false
        }
    }
}
