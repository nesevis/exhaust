/// A concrete sparse edit with its priority before a staged search's sampled grid. Lower priorities run first across all selected targets.
struct NumericPriorityProposal: Equatable {
    let priority: Int
    let probe: SparseEncoderProbe

    /// The proposals both staged cursors try before their grids: the group's sign flip, a rescaling by −1, then its ratio-preserving rescalings.
    ///
    /// Ranking the flip below every rescaling priority makes each cursor emit every group's flip before any rescaling, and the cursors skip grid points that repeat a priority proposal. The flip never duplicates a rescaling: rescalings apply only to integers and strictly shrink every nonzero magnitude, while the flip preserves magnitudes and changes at least one nonzero leaf.
    static func build(for leaves: [ReductionLeaf]) -> [NumericPriorityProposal] {
        let rescalings = NumericCommonDivisorProposal.rescalings(for: leaves).map { rescaling in
            NumericPriorityProposal(priority: rescaling.priority, probe: SparseEncoderProbe(leaves: leaves, patterns: rescaling.patterns))
        }
        guard let signFlip = SignFlipProposal.build(leaves: leaves) else {
            return rescalings
        }
        return [NumericPriorityProposal(priority: SignFlipProposal.priority, probe: signFlip)] + rescalings
    }
}
