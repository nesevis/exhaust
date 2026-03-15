/// 2-cell pruning of dominated encoders within a hom-set.
///
/// Within each hom-set (encoders sharing the same decoder), the dominance relation
/// defines when a less-aggressive encoder can be skipped because a more-aggressive one
/// has already succeeded. The 2-cell relationships are:
///
/// - **Deletion**: `deleteContainerSpans` ⇒ `speculativeDelete`
/// - **Value minimization**: `zeroValue` ⇒ `binarySearchToZero` ⇒ `binarySearchToTarget`
///
/// The lattice is scoped per hom-set: success in one hom-set (e.g., deletion) does not
/// affect dominance in another (e.g., value minimization). The scheduler resets the
/// lattice at leg boundaries where the decoder changes.
///
/// During the contravariant sweep (structure-preserving), the lattice is stable — no
/// structural changes occur. During the deletion sweep, the lattice must be invalidated
/// after each success (spans change). During the covariant sweep, the lattice is stable
/// again.
///
/// Reference: Sepulveda-Jimenez, Def 15.3 (2-cell dominance).
struct DominanceLattice {

    /// Encoders that have accepted at least one candidate since the last invalidation.
    private var succeeded: Set<String> = []

    /// Records that an encoder accepted a candidate.
    mutating func recordSuccess(_ name: String) {
        succeeded.insert(name)
    }

    /// Clears all success tracking. Called at leg boundaries or after structural changes
    /// that invalidate the span layout.
    mutating func invalidate() {
        succeeded.removeAll()
    }

    /// Returns `true` if the encoder should be skipped because a dominating encoder
    /// has already succeeded within the same hom-set.
    ///
    /// Only checks dominators within the same ``ReductionPhase`` — cross-phase
    /// dominance is not defined (the leg ordering handles inter-phase sequencing).
    func shouldSkip(_ name: String, phase: ReductionPhase) -> Bool {
        switch (phase, name) {
        // Container deletion is strictly more aggressive than speculative single-span deletion.
        case (.structuralDeletion, "speculativeDelete"):
            return succeeded.contains("deleteContainerSpans")
        // Zero is the best binary-search-to-zero can achieve.
        case (.valueMinimization, "binarySearchToZero"):
            return succeeded.contains("zeroValue")
        // Binary-search-to-zero finds values ≤ any nonzero target.
        case (.valueMinimization, "binarySearchToTarget"):
            return succeeded.contains("zeroValue") || succeeded.contains("binarySearchToZero")
        default:
            return false
        }
    }
}
