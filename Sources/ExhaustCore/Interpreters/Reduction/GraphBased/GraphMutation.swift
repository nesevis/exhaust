//
//  GraphMutation.swift
//  Exhaust
//

// MARK: - Projected Mutation

/// Encoder-published description of the mutation a probe would enact if accepted.
///
/// Each ``GraphEncoder`` returns a ``ProjectedMutation`` alongside its candidate sequence on every probe (Layer 3 of the partial-rebuild rollout). When the scheduler accepts a probe, it forwards the mutation to ``ChoiceGraph/apply(_:freshTree:)``, which performs the corresponding in-place update without rebuilding the graph from scratch.
///
/// Layer 2 introduces this enum and implements only the value-only fast path of ``leafValues(_:)``. The remaining cases are scaffolding for Layer 7's structural-encoder rollout — they all return ``ChangeApplication/requiresFullRebuild`` true until then.
///
/// - SeeAlso: ``LeafChange``, ``ChangeApplication``, ``LeafEntry``
enum ProjectedMutation {
    /// One or more leaf values changed. Each ``LeafChange``'s ``LeafChange/mayReshape`` flag tells the graph whether the change might trigger a downstream bind subtree rebuild.
    case leafValues([LeafChange])

    /// Sequence elements removed from one or more parent sequences. Each tuple identifies the parent sequence and the node IDs of the removed elements.
    case sequenceElementsRemoved([(seqNodeID: Int, removedNodeIDs: [Int])])

    /// Branch selection changed at a pick node. Layer 7.
    case branchSelected(pickNodeID: Int, newSelectedID: UInt64)

    /// Self-similar replacement: target subtree replaced by donor subtree. Layer 7.
    case selfSimilarReplaced(targetNodeID: Int, donorNodeID: Int)

    /// Descendant pick promoted into ancestor pick position. Layer 7.
    case descendantPromoted(ancestorPickNodeID: Int, descendantPickNodeID: Int)

    /// Sequence elements migrated between two sequences. Layer 7.
    case sequenceElementsMigrated(
        sourceSeqID: Int,
        receiverSeqID: Int,
        movedNodeIDs: [Int],
        insertionOffset: Int
    )

    /// Two same-shaped siblings swapped within a zip. Layer 7.
    case siblingsSwapped(zipNodeID: Int, idA: Int, idB: Int)
}

// MARK: - Leaf Change

/// One leaf change in a ``ProjectedMutation/leafValues(_:)`` report.
///
/// The encoder copies ``mayReshape`` from the originating ``LeafEntry/mayReshapeOnAcceptance`` without inspecting it. ``ChoiceGraph/apply(_:freshTree:)`` reads the flag to route between the value-only fast path and the bind-inner reshape path.
struct LeafChange {
    /// Identifier of the leaf node whose value changed.
    let leafNodeID: Int

    /// New value to write into the leaf's ``ChooseBitsMetadata``.
    let newValue: ChoiceValue

    /// True when the change may trigger a downstream bind subtree rebuild. Copied from the originating ``LeafEntry/mayReshapeOnAcceptance``.
    let mayReshape: Bool
}

// MARK: - Change Application

/// Result of applying a ``ProjectedMutation`` to a ``ChoiceGraph``.
///
/// Reports which nodes were touched, removed, or added; any position shifts applied; and a fallback flag (``requiresFullRebuild``) that the scheduler reads to decide whether to discard the partial application and rebuild the graph from scratch.
struct ChangeApplication {
    /// Node IDs whose values or metadata were updated in place.
    var touchedNodeIDs: Set<Int> = []

    /// Node IDs added to ``ChoiceGraph/removedNodeIDs`` by this application. Layer 4 populates these.
    var removedNodeIDs: Set<Int> = []

    /// Node IDs newly appended to ``ChoiceGraph/nodes`` by this application. Layer 4 populates these.
    var addedNodeIDs: Set<Int> = []

    /// Position shifts applied to right-of-insertion nodes. Layer 4 populates these.
    var positionShifts: [(insertionPoint: Int, delta: Int)] = []

    /// True when the partial-rebuild path cannot honour the mutation and the scheduler must fall back to ``ChoiceGraph/build(from:)``. Layer 2 sets this for every case except the value-only fast path of ``ProjectedMutation/leafValues(_:)`` with no reshape leaves.
    var requiresFullRebuild: Bool = false
}
