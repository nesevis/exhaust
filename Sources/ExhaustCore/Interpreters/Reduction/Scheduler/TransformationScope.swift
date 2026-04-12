//
//  TransformationScope.swift
//  Exhaust
//

// MARK: - Removal Scopes

/// Defines the scope of a subgraph removal operation.
///
/// Three scope granularities: element removal across one or more sequences, structural subtree removal, and covering-array-backed aligned removal across sibling sequences under a common zip.
enum RemovalScope {
    /// Remove elements from one or more sequences. Subsumes both single-parent removal and aligned removal across sibling sequences.
    case elements(ElementRemovalScope)

    /// Remove a structural subtree (bind subtree, zip child, or other compound element in the deletion antichain).
    case subtree(SubtreeRemovalScope)

    /// Covering-array-backed aligned removal across sibling sequences under a common zip. The encoder pulls rows from the covering array generator, decoding each into an element deletion combination with pairwise interaction coverage.
    case coveringAligned(CoveringAlignedRemovalScope)
}

/// Scope for element removal across one or more sequences.
///
/// Each ``SequenceRemovalTarget`` identifies a parent sequence and the element node IDs to remove from it. A single-target scope is the common case (removal within one sequence). Multi-target scopes enable cross-sequence batched removal for antichain-independent sequences.
struct ElementRemovalScope {
    /// Per-sequence removal targets.
    let targets: [SequenceRemovalTarget]

    /// Maximum batch size (for geometric halving in scope sources).
    let maxBatch: Int

    /// Yield of the largest single element across all targets.
    let maxElementYield: Int
}

/// One sequence's contribution to an ``ElementRemovalScope``.
struct SequenceRemovalTarget {
    /// The parent sequence node.
    let sequenceNodeID: Int

    /// Deletable element node IDs, ordered by position within the sequence.
    let elementNodeIDs: [Int]
}

/// Scope for structural subtree removal.
///
/// Targets compound elements in the deletion antichain — bind subtrees, zip children, or other structural nodes with ``ChoiceGraphNode/positionRange`` count greater than one.
struct SubtreeRemovalScope {
    /// The node to remove.
    let nodeID: Int

    /// Yield: position range count.
    let yield: Int
}

// MARK: - Covering Aligned Removal

/// ARC-managed handle for a ``PullBasedCoveringArrayGenerator`` that automatically deallocates the generator's internal bit vectors when the last reference is released.
final class CoveringArrayHandle {
    var generator: PullBasedCoveringArrayGenerator

    init(generator: PullBasedCoveringArrayGenerator) {
        self.generator = generator
    }

    deinit {
        generator.deallocate()
    }
}

/// Aligned removal scope backed by a strength-2 covering array over sibling sequence elements.
///
/// Each sibling sequence under a common zip becomes a parameter whose domain is `elementCount + 1` — the extra value encodes "skip this sibling" (do not delete from it). The covering array generator produces rows that guarantee pairwise coverage of all (sibling-A element, sibling-B element) interactions in O(max(domain)^2 * log(siblings)) rows, replacing the previous exponential subset enumeration and cross-product expansion.
///
/// The generator is wrapped in a ``CoveringArrayHandle`` for automatic deallocation via ARC. The encoder pulls rows from the generator on each ``GraphEncoder/nextProbe(lastAccepted:)`` call, decoding each row into deletion targets for candidate construction.
struct CoveringAlignedRemovalScope {
    /// The sibling sequences participating in aligned deletion.
    let siblings: [AlignedSibling]

    /// ARC-managed covering array generator. The encoder pulls rows from ``CoveringArrayHandle/generator`` via ``PullBasedCoveringArrayGenerator/next()``.
    let handle: CoveringArrayHandle

    /// Per-parameter domain value that encodes "skip this sibling." Equal to the sibling's element count (one past the last valid element index).
    let skipValues: [UInt64]

    /// Maximum single-element yield across all siblings. Used for the scope source's ``TransformationYield/structural`` estimate.
    let maxElementYield: Int

    /// One sibling sequence in the aligned deletion group.
    struct AlignedSibling {
        /// The parent sequence node ID.
        let sequenceNodeID: Int

        /// Deletable element node IDs, ordered by position within the sequence.
        let elementNodeIDs: [Int]
    }
}

// MARK: - Replacement Scopes

/// Defines the scope of a subgraph replacement operation.
///
/// Replacement is the only operation type that changes the generator's active execution path. Active donors (non-nil position range) enable sequence surgery. Inactive donors (nil position range) require tree edit and flatten.
enum ReplacementScope {
    /// Splice a donor subtree along a self-similarity edge.
    case selfSimilar(SelfSimilarReplacementScope)

    /// Change the selected branch at a pick node.
    case branchPivot(BranchPivotScope)

    /// Collapse one recursion level via direct descendant promotion.
    case descendantPromotion(DescendantPromotionScope)
}

/// Scope for self-similar subtree replacement.
struct SelfSimilarReplacementScope {
    /// Target node (larger) to be replaced.
    let targetNodeID: Int

    /// Donor node (smaller) providing replacement content.
    let donorNodeID: Int

    /// Size delta (positive = reduction).
    let sizeDelta: Int
}

/// Scope for branch pivot at a pick node.
///
/// Each scope targets one pick site and one non-selected alternative. The encoder uses the pick node's position range from the graph to locate and replace the relevant entries in the sequence directly.
struct BranchPivotScope {
    /// The pick node.
    let pickNodeID: Int

    /// The non-selected branch to try.
    let targetBranchID: UInt64
}

/// Scope for direct descendant promotion.
struct DescendantPromotionScope {
    /// The ancestor pick node.
    let ancestorPickNodeID: Int

    /// The descendant pick node to promote.
    let descendantPickNodeID: Int

    /// Estimated size reduction.
    let sizeDelta: Int
}

// MARK: - Minimization Scopes

/// Defines the scope of a value minimization operation.
///
/// Minimization drives leaf values toward their semantic simplest without changing graph structure. 
enum MinimizationScope {
    /// Search chooseBits leaf values toward their reduction targets.
    case valueLeaves(ValueMinimizationScope)

    /// Search float leaf values via the four-stage IEEE 754 pipeline.
    case floatLeaves(FloatMinimizationScope)

    /// Joint upstream/downstream minimization along a bind dependency edge. Each upstream probe on the controlling value triggers a full downstream search on the dependent subtree. Modelled as a single scope because the upstream and downstream are tightly interleaved at the probe level.
    case boundValue(BoundValueScope)

    /// Branch pivot composed with downstream value search. Tries each available branch at a pick node, materializes the pivoted tree, and runs value search on the result to find failures through a passing intermediate.
    case pivotThenMinimize(PivotMinimizeScope)
}

/// Per-leaf annotation in a value-only scope.
///
/// Carries the leaf's node ID plus a marker that tells the graph (on acceptance) whether mutating this leaf might trigger a downstream bind subtree rebuild. The encoder ignores ``mayReshapeOnAcceptance`` and minimizes the leaf value identically for both kinds. The marker rides along into the encoder's ``ProjectedMutation`` report so that ``ChoiceGraph/apply(_:freshTree:)`` can route between the value-only fast path and the bind-inner reshape path on a per-leaf basis.
///
/// Source builders populate ``mayReshapeOnAcceptance`` from graph metadata: the marker is true when the leaf is the inner child of a non-structurally-constant bind. Layer 4's extended ``ChoiceGraph/rebuildBoundSubtree(bindNodeID:newBoundTree:)`` is what makes the marker actionable; until then, any leaf change with the marker set causes ``ChoiceGraph/apply(_:freshTree:)`` to set ``ChangeApplication/requiresFullRebuild``.
struct LeafEntry {
    /// Identifier of the leaf node.
    let nodeID: Int

    /// True when this leaf is the inner child of a non-structurally-constant bind. Encoders ignore this; the graph reads it on acceptance.
    let mayReshapeOnAcceptance: Bool

    init(nodeID: Int, mayReshapeOnAcceptance: Bool = false) {
        self.nodeID = nodeID
        self.mayReshapeOnAcceptance = mayReshapeOnAcceptance
    }
}

/// Scope for integer leaf value minimization.
struct ValueMinimizationScope {
    /// Leaves to minimise, ordered by value yield descending (bind-inner leaves with large bound subtrees first). Each entry carries the bind-inner reshape marker so the graph can route value updates per leaf without the encoder having to know.
    let leaves: [LeafEntry]

    /// Whether batch zeroing should be attempted first.
    let batchZeroEligible: Bool

    /// Backward-compat shorthand for the encoder's existing read pattern. Layer 3 will update encoders to read ``leaves`` directly and remove this property.
    var leafNodeIDs: [Int] {
        leaves.map(\.nodeID)
    }
}

/// Scope for float leaf value minimization.
struct FloatMinimizationScope {
    /// Float leaves to minimise. Each entry carries the bind-inner reshape marker.
    let leaves: [LeafEntry]

    /// Backward-compat shorthand. Layer 3 will update encoders to read ``leaves`` directly.
    var leafNodeIDs: [Int] {
        leaves.map(\.nodeID)
    }
}

/// Scope for joint upstream/downstream value search along a bind dependency edge.
struct BoundValueScope {
    /// The bind node whose dependency edge is being explored.
    let bindNodeID: Int

    /// The upstream bind-inner leaf to search.
    let upstreamLeafNodeID: Int

    /// Node IDs in the downstream bound subtree.
    let downstreamNodeIDs: [Int]

    /// The bound subtree's position count (value yield of the compound).
    let boundSubtreeSize: Int
}

/// Scope for branch pivot composed with downstream value search.
struct PivotMinimizeScope {
    /// The pick node to pivot.
    let pickNodeID: Int

    /// Number of alternative branches (excluding current). Used for yield estimation.
    let alternativeBranchCount: Int

    /// Position count of the pick node's subtree.
    let subtreeSize: Int
}

// MARK: - Exchange Scopes

/// Defines the scope of a value exchange operation.
///
/// Exchange moves magnitude between leaves to enable future operations. It is an approximate reduction with affine slack in the categorical framework — the intermediate may be shortlex-larger than the starting point.
enum ExchangeScope {
    /// Speculative value swaps along type-compatibility edges.
    case redistribution(RedistributionScope)

    /// Lockstep reduction of same-typed sibling values.
    case tandem(TandemScope)
}

/// Scope for redistribution along type-compatibility edges.
struct RedistributionScope {
    /// Source-sink pairs from type-compatibility edges, ordered by Nash-gap regret.
    let pairs: [RedistributionPair]
}

/// A single source-sink pair for redistribution.
struct RedistributionPair {
    /// The source leaf (non-zero, can donate magnitude).
    let source: LeafEntry

    /// The sink leaf (zero or near-target, can absorb magnitude).
    let sink: LeafEntry

    /// The source leaf's type tag.
    let sourceTag: TypeTag

    /// The sink leaf's type tag. Equal to ``sourceTag`` for same-type pairs, different for cross-type (for example float ↔ int) pairs.
    let sinkTag: TypeTag

    /// Backward-compat shorthand. Layer 3 will update encoders to read ``source`` directly.
    var sourceNodeID: Int {
        source.nodeID
    }

    /// Backward-compat shorthand. Layer 3 will update encoders to read ``sink`` directly.
    var sinkNodeID: Int {
        sink.nodeID
    }
}

/// Scope for tandem lockstep reduction.
struct TandemScope {
    /// Groups of same-typed leaves eligible for lockstep reduction.
    let groups: [TandemGroup]
}

/// A group of same-typed leaves for tandem reduction.
struct TandemGroup {
    /// Leaves in this group, each carrying the bind-inner reshape marker.
    let leaves: [LeafEntry]

    /// The shared type tag.
    let typeTag: TypeTag

    /// Backward-compat shorthand. Layer 3 will update encoders to read ``leaves`` directly.
    var leafNodeIDs: [Int] {
        leaves.map(\.nodeID)
    }
}

// MARK: - Permutation Scopes

/// Defines the scope of a permutation operation.
///
/// Permutation reorders children at a node without modifying structure or values. It is an exact reduction with zero structural and value yield, accepted purely on shortlex improvement.
enum PermutationScope {
    /// Reorder same-shaped siblings within a zip node.
    case siblingPermutation(SiblingPermutationScope)
}

/// Scope for sibling permutation at a parent node (zip or sequence).
struct SiblingPermutationScope {
    /// The parent node whose children may be permuted. May be a zip or a sequence.
    let parentNodeID: Int

    /// Groups of same-shaped children that can be swapped. Each inner array contains node IDs of children with the same structural shape.
    let swappableGroups: [[Int]]
}

// MARK: - Migration Scopes

/// Defines the scope of an element migration between antichain-independent sequences.
///
/// Migration moves elements from an earlier sequence to a later sequence to improve shortlex ordering. The source sequence becomes shorter (improving shortlex at earlier positions). The receiver sequence absorbs the elements.
///
/// This is a pure structural operation: the graph specifies exactly which elements to move and where. One scope = one probe.
struct MigrationScope {
    /// The source sequence node (earlier in position, becomes shorter).
    let sourceSequenceNodeID: Int

    /// The receiver sequence node (later in position, becomes longer).
    let receiverSequenceNodeID: Int

    /// Element node IDs to move from source to receiver, ordered by position.
    let elementNodeIDs: [Int]

    /// Position ranges of the elements being moved.
    let elementPositionRanges: [ClosedRange<Int>]

    /// Position range of the receiver sequence (elements are appended after its current content).
    let receiverPositionRange: ClosedRange<Int>
}

// MARK: - Transformation Scope

/// Bundles a graph transformation with its base sequence, tree, graph, and warm-start convergence records into a self-contained unit of work for an encoder.
///
/// The encoder receives a scope and operates on it without modifying the graph — the scope is the interface between the graph (which constructs it) and the encoder (which consumes it).
///
/// For simple transformations, ``baseSequence`` is the current sequence. For bound value composition, the downstream scope's ``baseSequence`` is the lifted result from the upstream probe — the encoder does not know or care that it is downstream.
///
/// - Note: The graph is carried temporarily for node metadata access (position ranges, leaf values). A future refinement will pre-resolve all needed metadata into the scope types and remove the graph dependency.
struct TransformationScope {
    /// The transformation to execute (operation, yield, precondition, postcondition).
    let transformation: GraphTransformation

    /// The sequence the encoder operates on. The encoder modifies this sequence to produce candidates.
    let baseSequence: ChoiceSequence

    /// The generator's compositional structure. Required for path-changing operations (replacement with inactive donor) where the encoder must edit the tree and flatten. Also used by permutation for tree-based child swapping.
    let tree: ChoiceTree

    /// The current choice graph. Provides node metadata (position ranges, leaf values, type tags) for candidate construction. The encoder reads from the graph but never mutates it.
    ///
    /// - Note: Temporary — a future refinement will pre-resolve metadata into scope types, making the graph unnecessary.
    let graph: ChoiceGraph

    /// Warm-start convergence records for leaves in this scope, keyed by graph **nodeID**.
    ///
    /// Extracted from graph nodes at scope construction time via ``ChoiceGraphScheduler/extractWarmStarts(from:)``. NodeID keying lets the encoder look up records via `state.warmStartRecords[leaf.nodeID]` and survive any in-pass position shift triggered by ``GraphEncoder/refreshScope(graph:sequence:)``. The encoder never accesses the graph directly for convergence data.
    let warmStartRecords: [Int: ConvergedOrigin]
}
