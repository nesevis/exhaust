//
//  GraphMutation.swift
//  Exhaust
//

// MARK: - Projected Mutation

/// Encoder-published description of the mutation a probe would enact if accepted.
///
/// Each ``GraphEncoder`` returns a ``ProjectedMutation`` alongside its candidate sequence on every probe. When the scheduler accepts a probe, it forwards the mutation to ``ChoiceGraph/apply(_:freshTree:)``, which performs the corresponding in-place update without rebuilding the graph from scratch.
///
/// - SeeAlso: ``LeafChange``, ``ChangeApplication``, ``LeafEntry``
package enum ProjectedMutation {
    /// One or more leaf values changed. Each ``LeafChange``'s ``LeafChange/mayReshape`` flag tells the graph whether the change might trigger a downstream bind subtree rebuild.
    case leafValues([LeafChange])

    /// Sequence elements removed from one or more parent sequences. Each tuple identifies the parent sequence and the node IDs of the removed elements.
    case sequenceElementsRemoved([(seqNodeID: Int, removedNodeIDs: [Int])])

    /// Branch selection changed at a pick node.
    case branchSelected(pickNodeID: Int, newSelectedID: UInt64)

    /// Self-similar replacement: target subtree replaced by donor subtree.
    case selfSimilarReplaced(targetNodeID: Int, donorNodeID: Int)

    /// Descendant pick promoted into ancestor pick position.
    case descendantPromoted(ancestorPickNodeID: Int, descendantPickNodeID: Int)

    /// Sequence elements migrated between two sequences.
    case sequenceElementsMigrated(
        sourceSeqID: Int,
        receiverSeqID: Int,
        movedNodeIDs: [Int],
        insertionOffset: Int
    )

    /// Two same-shaped siblings swapped within a parent (zip or sequence).
    case siblingsSwapped(parentNodeID: Int, lhs: Int, rhs: Int)

    /// Sequence elements permuted into natural numeric order by ``GraphReorderEncoder``.
    ///
    /// The graph's in-place apply path does not implement sequence reordering; the scheduler performs a full rebuild from `freshTree` after any accepted probe. Only dispatched by the post-loop reorder pass where graph freshness after the accepted probe is not required.
    case sequenceReordered
}

// MARK: - Leaf Change

/// One leaf change in a ``ProjectedMutation/leafValues(_:)`` report.
///
/// The encoder copies ``mayReshape`` from the originating ``LeafEntry/mayReshapeOnAcceptance`` without inspecting it. ``ChoiceGraph/apply(_:)`` reads the flag: a value-only change is written in place, while a `mayReshape` change sets ``ChangeApplication/requiresFullRebuild`` so the scheduler rebuilds the graph from the fresh tree.
package struct LeafChange {
    /// Identifier of the leaf node whose value changed.
    package let leafNodeID: Int

    /// New value to write into the leaf's ``ChooseBitsMetadata``.
    package let newValue: ChoiceValue

    /// True when the change may trigger a downstream bind subtree rebuild. Copied from the originating ``LeafEntry/mayReshapeOnAcceptance``.
    package let mayReshape: Bool

    package init(leafNodeID: Int, newValue: ChoiceValue, mayReshape: Bool) {
        self.leafNodeID = leafNodeID
        self.newValue = newValue
        self.mayReshape = mayReshape
    }
}

// MARK: - Change Application

/// Result of applying a ``ProjectedMutation`` to a ``ChoiceGraph``.
///
/// Reports which nodes were touched and a fallback flag (``requiresFullRebuild``) that the scheduler reads to decide whether to rebuild the graph from scratch.
package struct ChangeApplication {
    /// Node IDs whose values or metadata were updated in place.
    package var touchedNodeIDs: Set<Int> = []

    /// True when the mutation requires a full graph rebuild via ``ChoiceGraph/build(from:)``. Set for every case except the value-only fast path of ``ProjectedMutation/leafValues(_:)`` with no reshape leaves.
    package var requiresFullRebuild: Bool = false
}
