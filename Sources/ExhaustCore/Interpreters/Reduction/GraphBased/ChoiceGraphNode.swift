//
//  ChoiceGraphNode.swift
//  Exhaust
//

// MARK: - Node Kind

/// Classifies a node in the ``ChoiceGraph`` by the value-structural operation it represents.
///
/// Five kinds correspond to the five ``ReflectiveOperation`` cases that produce or compose values. Operational cases (`contramap`, `prune`, `getSize`, `resize`, `filter`, `classify`, `unique`) and forward-only transforms (`.map`, `.metamorphic`) are not represented — they are interpreter concerns. `just` is invisible (no choices).
///
/// ## chooseBits
/// Leaf node producing a single value. Carries ``TypeTag``, valid range, and the current ``ChoiceValue`` from the ``ChoiceSequence``. Addressable unit for value redistribution.
///
/// ## pick
/// Branch selector with one containment edge per possible branch. The active branch has a populated subtree from the current counterexample. Inactive branches have full structural information (from `materializePicks`) but nil position ranges — they are atomic pivot/promotion targets, not reducible within. Pick nodes are the source of self-similarity edges.
///
/// ## bind
/// Dependency node with two children: inner (value-producing) and bound (structure depends on inner). The bound subtree is a dynamic region rebuilt when the inner value changes (unless structurally constant).
///
/// ## zip
/// Parallel composition. Children are structurally independent — no ordering constraint. Defines the independence structure for antichain computation.
///
/// ## sequence
/// Dynamic element children with an optional length constraint. The element count depends on the current counterexample. The materialiser derives actual length from element count, not from the length generator's output.
public enum ChoiceGraphNodeKind {
    /// Leaf value with type, range, and current value.
    case chooseBits(ChooseBitsMetadata)

    /// Branch selector at a pick site.
    case pick(PickMetadata)

    /// Data-dependent bind where the inner value controls the bound subtree's structure.
    case bind(BindMetadata)

    /// Parallel composition of independent children.
    case zip(ZipMetadata)

    /// Variable-length sequence with dynamic element children.
    case sequence(SequenceMetadata)
}

// MARK: - Per-Kind Metadata

/// Metadata for a ``ChoiceGraphNodeKind/chooseBits(_:)`` leaf node.
public struct ChooseBitsMetadata {
    /// Semantic type of the value.
    public let typeTag: TypeTag

    /// Valid bit-pattern range from the generator, or nil if unconstrained.
    public let validRange: ClosedRange<UInt64>?

    /// Whether the range was user-specified or derived from size scaling.
    public let isRangeExplicit: Bool

    /// Current value from the ``ChoiceSequence``.
    public let value: ChoiceValue

    /// Cached convergence floor from a prior value search pass, or nil if this leaf has not been searched. Invalidated on structural changes.
    public var convergedOrigin: ConvergedOrigin?
}

/// Metadata for a ``ChoiceGraphNodeKind/pick(_:)`` branch selector node.
public struct PickMetadata {
    /// Pick site identifier including depth encoding for recursive generators.
    public let siteID: UInt64

    /// Site identifier with depth contribution stripped (`siteID / 1000`). Two picks with matching values belong to the same recursive generator at different depths. Legacy mechanism — once the graph subsumes the current reducer, depth is structural and the masking can be removed.
    public let depthMaskedSiteID: UInt64

    /// All valid branch identifiers at this site.
    public let branchIDs: [UInt64]

    /// Currently selected branch identifier.
    public let selectedID: UInt64

    /// Index into the parent node's ``ChoiceGraphNode/children`` identifying the active branch child.
    public let selectedChildIndex: Int
}

/// Metadata for a ``ChoiceGraphNodeKind/bind(_:)`` dependency node.
public struct BindMetadata {
    /// Whether the bound subtree contains no nested binds or picks, meaning the inner value controls ranges and counts but not tree shape.
    public let isStructurallyConstant: Bool

    /// Nesting depth of enclosing bind regions.
    public let bindDepth: Int

    /// Index into the parent node's ``ChoiceGraphNode/children`` identifying the inner (controlling) child.
    public let innerChildIndex: Int

    /// Index into the parent node's ``ChoiceGraphNode/children`` identifying the bound (controlled) child.
    public let boundChildIndex: Int
}

/// Metadata for a ``ChoiceGraphNodeKind/zip(_:)`` parallel composition node.
public struct ZipMetadata {
    /// When true, coverage analysis skips this subtree.
    public let isOpaque: Bool
}

/// Metadata for a ``ChoiceGraphNodeKind/sequence(_:)`` node.
public struct SequenceMetadata {
    /// Explicit length range from ``ChoiceMetadata``, if any. Constrains deletion — the reducer cannot delete below the lower bound. This is metadata on the node, not a containment edge to a child.
    public let lengthConstraint: ClosedRange<UInt64>?

    /// Current element count from the ``ChoiceSequence``.
    public let elementCount: Int
}

// MARK: - Node

/// A node in the ``ChoiceGraph`` representing a value-structural operation in the generator.
///
/// Each node stores its identity, kind with per-kind metadata, position mapping to the flat ``ChoiceSequence``, and parent-child relationships forming the containment tree.
public struct ChoiceGraphNode {
    /// Stable identity assigned during graph construction.
    public let id: Int

    /// The value-structural operation this node represents.
    public let kind: ChoiceGraphNodeKind

    /// Range of ``ChoiceSequence`` indices this node covers, or nil for inactive (unselected) branches. Encoders that modify the sequence can only target nodes with non-nil position ranges.
    public let positionRange: ClosedRange<Int>?

    /// Indices of child nodes in ``ChoiceGraph/nodes``.
    public let children: [Int]

    /// Index of the parent node in ``ChoiceGraph/nodes``, or nil for the root.
    public let parent: Int?
}
