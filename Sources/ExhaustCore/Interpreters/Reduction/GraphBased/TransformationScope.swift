//
//  TransformationScope.swift
//  Exhaust
//

// MARK: - Removal Scopes

/// Defines the scope of a subgraph removal operation.
///
/// Three scope granularities, all the same graph operation at different scales: aligned removal across sibling sequences, per-parent removal within a single sequence, and structural subtree removal.
enum RemovalScope {
    /// Remove elements at aligned offsets across sibling sequences under a common zip node. Container emptying is the degenerate case where the window covers all elements of one sequence.
    case aligned(AlignedRemovalScope)

    /// Remove elements from a single parent sequence.
    case perParent(PerParentRemovalScope)

    /// Remove a structural subtree (bind subtree, zip child, or other compound element in the deletion antichain).
    case subtree(SubtreeRemovalScope)
}

/// Scope for aligned removal across sibling sequences.
///
/// Groups elements at corresponding offsets across sibling sequences under a common zip node. The encoder handles window placement (head-aligned, tail-aligned, or both) within its probe loop.
struct AlignedRemovalScope {
    /// The zip node whose children are sibling sequences.
    let zipNodeID: Int

    /// Participating sibling sequences and their deletable elements.
    let siblings: [SiblingDeletionScope]

    /// Maximum number of aligned offsets removable (minimum deletable count across siblings).
    let maxAlignedWindow: Int

    /// Total yield if the full aligned window is removed.
    let maxYield: Int
}

/// One sibling's contribution to an aligned removal scope.
struct SiblingDeletionScope {
    /// The sequence node ID.
    let sequenceNodeID: Int

    /// Element node IDs ordered by offset within the sequence.
    let elementNodeIDs: [Int]

    /// How many elements can be removed (elementCount - lowerBound).
    let deletableCount: Int
}

/// Scope for per-parent removal within a single sequence.
struct PerParentRemovalScope {
    /// The parent sequence node.
    let sequenceNodeID: Int

    /// Deletable element node IDs, ordered by position.
    let elementNodeIDs: [Int]

    /// Maximum batch size.
    let maxBatch: Int

    /// Yield of the largest single element.
    let maxElementYield: Int
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
struct BranchPivotScope {
    /// The pick node.
    let pickNodeID: Int

    /// Alternative branch IDs to try, ordered by estimated yield.
    let candidateBranchIDs: [UInt64]
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

// MARK: - Minimisation Scopes

/// Defines the scope of a value minimisation operation.
///
/// Minimisation drives leaf values toward their semantic simplest without changing graph structure. It is a Kleisli arrow (nondeterministic multi-probe search) in the categorical framework.
enum MinimisationScope {
    /// Search integer leaf values toward their reduction targets.
    case integerLeaves(IntegerMinimisationScope)

    /// Search float leaf values via the four-stage IEEE 754 pipeline.
    case floatLeaves(FloatMinimisationScope)

    /// Joint upstream/downstream minimisation along a dependency edge.
    ///
    /// Categorically a Kleisli composition of two Kleisli arrows (Section 7.5 of the categorical framework). Modelled as a single scope rather than a ``CompoundTransformation`` because the upstream and downstream are tightly interleaved at the probe level: each upstream probe spawns a downstream search, and convergence transfers between adjacent upstream probes via the delta-1 structural fingerprint check.
    case kleisliFibre(KleisliFibreScope)
}

/// Scope for integer leaf value minimisation.
struct IntegerMinimisationScope {
    /// Leaf node IDs to minimise, ordered by value yield descending (bind-inner leaves with large bound subtrees first).
    let leafNodeIDs: [Int]

    /// Whether batch zeroing should be attempted first.
    let batchZeroEligible: Bool
}

/// Scope for float leaf value minimisation.
struct FloatMinimisationScope {
    /// Float leaf node IDs to minimise.
    let leafNodeIDs: [Int]
}

/// Scope for Kleisli fibre search along a dependency edge.
struct KleisliFibreScope {
    /// The bind node whose dependency edge is being explored.
    let bindNodeID: Int

    /// The upstream bind-inner leaf to search.
    let upstreamLeafNodeID: Int

    /// Node IDs in the downstream bound subtree.
    let downstreamNodeIDs: [Int]

    /// The bound subtree's position count (value yield of the compound).
    let boundSubtreeSize: Int
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
    let sourceNodeID: Int

    /// The sink leaf (zero or near-target, can absorb magnitude).
    let sinkNodeID: Int

    /// The shared type tag for type-compatibility.
    let typeTag: TypeTag
}

/// Scope for tandem lockstep reduction.
struct TandemScope {
    /// Groups of same-typed leaves eligible for lockstep reduction.
    let groups: [TandemGroup]
}

/// A group of same-typed leaves for tandem reduction.
struct TandemGroup {
    /// Leaf node IDs in this group.
    let leafNodeIDs: [Int]

    /// The shared type tag.
    let typeTag: TypeTag
}

// MARK: - Permutation Scopes

/// Defines the scope of a permutation operation.
///
/// Permutation reorders children at a node without modifying structure or values. It is an exact reduction with zero structural and value yield, accepted purely on shortlex improvement.
enum PermutationScope {
    /// Reorder same-shaped siblings within a zip node.
    case siblingPermutation(SiblingPermutationScope)
}

/// Scope for sibling permutation at a zip node.
struct SiblingPermutationScope {
    /// The zip node whose children may be permuted.
    let zipNodeID: Int

    /// Groups of same-shaped children that can be swapped. Each inner array contains node IDs of children with the same structural shape.
    let swappableGroups: [[Int]]
}

// MARK: - Transformation Scope

/// Bundles a graph transformation with its base sequence, tree, and warm-start convergence records into a self-contained unit of work for an encoder.
///
/// The encoder receives a scope and operates on it without needing the graph — the scope is the interface between the graph (which constructs it) and the encoder (which consumes it).
///
/// For simple transformations, ``baseSequence`` is the current sequence. For Kleisli composition, the downstream scope's ``baseSequence`` is the lifted result from the upstream probe — the encoder does not know or care that it is downstream.
struct TransformationScope {
    /// The transformation to execute (operation, yield, precondition, postcondition).
    let transformation: GraphTransformation

    /// The sequence the encoder operates on. For active-path operations, all position ranges are pre-resolved from graph nodes at scope construction — no additional flatten needed. The encoder modifies this sequence to produce candidates.
    let baseSequence: ChoiceSequence

    /// The tree. Required only for path-changing operations (replacement with inactive donor) where the encoder must edit the tree and flatten. Nil for active-path operations.
    let tree: ChoiceTree?

    /// Warm-start convergence records for leaves in this scope, extracted from graph nodes at scope construction time. The encoder reads warm-start bounds from here — it never accesses the graph directly.
    let warmStartRecords: [Int: ConvergedOrigin]
}
