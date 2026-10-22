/// Retains numeric domain metadata while ranking proposals before a staged search's sampled grid; execution converts the selected values into sequence edits only when emitted.
struct NumericPriorityProposal: Equatable {
    let priority: Int
    let leaves: [ReductionLeaf]
    let patterns: [UInt64]

    /// The proposals both staged cursors try before their grids: the group's sign flip, a rescaling by −1, then its ratio-preserving rescalings.
    ///
    /// Ranking the flip below every rescaling priority makes each cursor emit every group's flip before any rescaling, and the cursors skip grid points that repeat a priority proposal. The flip never duplicates a rescaling: rescalings apply only to integers and strictly shrink every nonzero magnitude, while the flip preserves magnitudes and changes at least one nonzero leaf.
    static func build(for leaves: [ReductionLeaf]) -> [NumericPriorityProposal] {
        let rescalings = NumericCommonDivisorProposal.rescalings(for: leaves).map { rescaling in
            NumericPriorityProposal(priority: rescaling.priority, leaves: leaves, patterns: rescaling.patterns)
        }
        guard let signFlip = SignFlipProposal.build(leaves: leaves) else {
            return rescalings
        }
        return [signFlip] + rescalings
    }
}
