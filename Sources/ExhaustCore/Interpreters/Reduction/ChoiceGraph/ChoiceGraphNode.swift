//
//  ChoiceGraphNode.swift
//  Exhaust
//

// MARK: - Node Kind

/// Classifies a node in the ``ChoiceGraph`` by the value-structural operation it represents.
///
/// Six kinds correspond to the structural cases that produce or compose values. Operational cases (`contramap`, `prune`, `getSize`, `resize`, `filter`, `classify`, `unique`) and forward-only transforms (`.map`, `.metamorphic`) are not represented — they are interpreter concerns. `just` is a visible constant leaf so that constant elements inside sequences are reachable by the removal encoder.
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
/// Dynamic element children with an optional length constraint. The element count depends on the current counterexample. The materializer derives actual length from element count, not from the length generator's output.
///
/// ## just
/// Constant leaf with no value choices — corresponds to `.pure` in the Freer Monad. Position range covers its single sequence entry. No metadata needed. Treated like `chooseBits` for dependency-edge purposes (no edges) but excluded from leaf-position and value-minimisation passes.
package enum ChoiceGraphNodeKind {
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

    /// Constant leaf with no value choices — corresponds to `.pure` in the Freer Monad. Emitted so that constant elements inside sequences appear in the containment tree and are reachable by the removal encoder.
    case just
}

// MARK: - Per-Kind Metadata

/// Metadata for a ``ChoiceGraphNodeKind/chooseBits(_:)`` leaf node.
package struct ChooseBitsMetadata {
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
package struct PickMetadata {
    /// Pick site fingerprint. Two picks with matching values belong to the same recursive generator (possibly at different depths).
    public let fingerprint: UInt64

    /// All valid branch identifiers at this site.
    public let branchIDs: [UInt64]

    /// Currently selected branch identifier.
    public let selectedID: UInt64

    /// Index into the parent node's ``ChoiceGraphNode/children`` identifying the active branch child.
    public let selectedChildIndex: Int

    /// Per-branch tree elements at this pick site, in the same order as the parent ``ChoiceGraphNode/children``. Each entry is the original `.branch(...)` element (or `.selected(.branch(...))` for the active branch) as it existed in the tree at graph construction time. The graph stores these so that ``GraphReplacementEncoder`` can enumerate branch alternatives without reading from the live tree, which may have been stripped by ``Materializer`` calls with `materializePicks: false`.
    public let branchElements: [ChoiceTree]
}

/// Metadata for a ``ChoiceGraphNodeKind/bind(_:)`` dependency node.
package struct BindMetadata {
    /// Stable hash of the originating `.bind` source location, carried through from ``ReflectiveOperation/transform(kind:inner:)`` (via ``ChoiceTree/bind(fingerprint:inner:bound:)``) to identify this bind site across graph rebuilds. Used by ``ChoiceGraph/bindClassifications`` to cache the classification verdict — the same source location always produces the same closure shape, so the verdict is invariant under graph rebuilds.
    public let fingerprint: UInt64

    /// Whether the bound subtree contains no nested binds or picks, meaning the inner value controls ranges and counts but not tree shape.
    public let isStructurallyConstant: Bool

    /// Nesting depth of enclosing bind regions.
    public let bindDepth: Int

    /// Index into the parent node's ``ChoiceGraphNode/children`` identifying the inner (controlling) child.
    public let innerChildIndex: Int

    /// Index into the parent node's ``ChoiceGraphNode/children`` identifying the bound (controlled) child.
    public let boundChildIndex: Int

    /// Structural path from the ``ChoiceTree`` root at graph-construction time to this bind. Used by ``ChoiceGraph/extractBoundSubtree(from:matchingPath:)`` to locate the matching bind in a post-mutation freshTree. The root bind has the empty path.
    public let bindPath: BindPath

    /// Cached classification recorded by ``ChoiceGraph/classifyBind(at:gen:scope:upstreamLeafNodeID:)``. Nil until the bind is classified, or after a reshape clears the prior result. Read by the scheduler before dispatching expensive dependent-node encoders (for example ``GraphComposedEncoder``) so unsuitable sites are skipped immediately rather than via emergent futility counting.
    public var classification: BindClassification?

    /// Topology hash of the bound subtree at classification time. Nil until classification runs. Intended as a future-facing staleness check: callers may re-hash the current bound subtree and compare against this value before trusting a cached ``classification``. Today, reshape clearing and full-graph-rebuild replacement already cover the common invalidation paths, so this field is defensive rather than load-bearing.
    public var downstreamFingerprint: UInt64?

    public init(
        fingerprint: UInt64,
        isStructurallyConstant: Bool,
        bindDepth: Int,
        innerChildIndex: Int,
        boundChildIndex: Int,
        bindPath: BindPath,
        classification: BindClassification? = nil,
        downstreamFingerprint: UInt64? = nil
    ) {
        self.fingerprint = fingerprint
        self.isStructurallyConstant = isStructurallyConstant
        self.bindDepth = bindDepth
        self.innerChildIndex = innerChildIndex
        self.boundChildIndex = boundChildIndex
        self.bindPath = bindPath
        self.classification = classification
        self.downstreamFingerprint = downstreamFingerprint
    }
}

// MARK: - Bind Classification

/// Classifies a bind site by how its bound subtree responds to variation in the upstream value.
///
/// Produced by ``ChoiceGraph/classifyBind(at:gen:scope:upstreamLeafNodeID:)``. Stored on ``BindMetadata/classification``. Read by expensive dependent-node encoders before dispatch.
package struct BindClassification: Equatable, Hashable, Sendable {
    /// Structural relationship between the bound subtrees lifted at the upstream range's low and high endpoints.
    public let topology: BindTopology

    /// Which of the two endpoint lifts succeeded.
    public let liftability: BindLiftability

    public init(topology: BindTopology, liftability: BindLiftability) {
        self.topology = topology
        self.liftability = liftability
    }
}

/// Shape-stability verdict from the classifier's two lifts.
package enum BindTopology: Equatable, Hashable, Sendable {
    /// The two lifted bound subtrees have the same skeleton — same node kinds and child counts at matching positions. Leaf-level descriptor differences (tag, width, range) do not break this verdict; they are the signal expensive encoders such as ``GraphComposedEncoder`` converge on.
    case identical
    /// The two lifted bound subtrees disagree on node kind or child count at some non-leaf position. Binary-search-style dependent-node encoders cannot converge because each upstream probe reshapes the downstream topology.
    case divergent
    /// The classifier could not produce a comparison: singleton upstream domain, both lifts threw, or the walk could not be performed.
    case unclassifiable
}

/// Reports which range endpoints the classifier was able to lift.
package enum BindLiftability: Equatable, Hashable, Sendable {
    /// Both endpoints materialized successfully.
    case both
    /// Only the low endpoint materialized.
    case lowOnly
    /// Only the high endpoint materialized.
    case highOnly
    /// Neither endpoint materialized.
    case neither
}

/// Snapshot of a bind site's upstream value and downstream topology at a given graph state. Compared across graph rebuilds to passively classify binds without materialisation probes.
package struct BindTopologyObservation: Equatable, Hashable, Sendable {
    /// Bit pattern of the upstream (inner) leaf at observation time.
    public let upstreamBitPattern: UInt64

    /// Topology fingerprint of the bound subtree at observation time.
    public let downstreamFingerprint: UInt64
}

/// Metadata for a ``ChoiceGraphNodeKind/zip(_:)`` parallel composition node.
package struct ZipMetadata {
    /// When true, coverage analysis skips this subtree.
    public let isOpaque: Bool
}

/// Metadata for a ``ChoiceGraphNodeKind/sequence(_:)`` node.
package struct SequenceMetadata {
    /// Explicit length range from ``ChoiceMetadata``, if any. Constrains deletion — the reducer cannot delete below the lower bound. This is metadata on the node, not a containment edge to a child.
    public let lengthConstraint: ClosedRange<UInt64>?

    /// Current element count from the ``ChoiceSequence``.
    public let elementCount: Int

    /// Full ``ChoiceSequence`` extent of each direct child element, including any transparent wrapper markers (group/bind from getSize-bind, transform-bind, and so on). Indexed parallel to ``ChoiceGraphNode/children``. Per-element removal must delete the full extent — removing only the inner chooseBits position leaves orphan markers that the materializer cannot decode.
    public let childPositionRanges: [ClosedRange<Int>]

    /// Common ``TypeTag`` of all elements when the sequence is type-homogeneous, or nil for heterogeneous or empty sequences.
    ///
    /// Derived bottom-up at graph construction time from two cases:
    /// - Direct: all children are ``ChoiceGraphNodeKind/chooseBits(_:)`` with the same tag.
    /// - Nested: all children are ``ChoiceGraphNodeKind/sequence(_:)`` with the same non-nil ``elementTypeTag``, implying subsequence homogeneity.
    ///
    /// When non-nil, any two leaves within the sequence are type-compatible for redistribution without materializing pairwise edges. The exchange scope builder uses this to construct ``RedistributionGroup`` descriptors in O(1) per sequence instead of O(C^2) per sequence.
    public let elementTypeTag: TypeTag?
}

// MARK: - Node

/// A node in the ``ChoiceGraph`` representing a value-structural operation in the generator.
///
/// Each node stores its identity, kind with per-kind metadata, position mapping to the flat ``ChoiceSequence``, and parent-child relationships forming the containment tree.
package struct ChoiceGraphNode {
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
