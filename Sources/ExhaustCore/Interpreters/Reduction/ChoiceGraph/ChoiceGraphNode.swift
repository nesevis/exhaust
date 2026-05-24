//
//  ChoiceGraphNode.swift
//  Exhaust
//

// MARK: - Node

/// A node in the ``ChoiceGraph`` representing a value-structural operation in the generator.
///
/// Inactive (unselected) branches carry a nil ``positionRange`` and do not address live entries in the ``ChoiceSequence``. Encoders must skip these nodes. Only nodes with a non-nil position range correspond to mutable sequence positions.
package struct ChoiceGraphNode {
    /// Assigned sequentially during graph construction. Unstable across rebuilds — the same logical node gets a different ID after any structural change.
    package let id: Int

    /// Determines which encoder passes may target this node. Value encoders target chooseBits leaves, structural encoders target pick, sequence, and bind nodes.
    package let kind: ChoiceGraphNodeKind

    /// Range of ``ChoiceSequence`` indices this node covers, or nil for inactive (unselected) branches. Encoders that modify the sequence can only target nodes with non-nil position ranges.
    package let positionRange: ClosedRange<Int>?

    /// Ordered by position in the ``ChoiceSequence``. For pick nodes, index corresponds to branch ID; for sequences, index corresponds to element ordinal.
    package let children: [Int]

    /// Nil only for the root. Used by scope queries to find enclosing bind and pick contexts for dependency analysis.
    package let parent: Int?

    /// Structural address from the tree root to this node. Stable across rebuilds as long as the tree shape above this node does not change. Two nodes in successive graphs with the same ``ChoicePath`` are the same logical node.
    package let choicePath: ChoicePath

    /// Pre-computed scope properties derivable during the tree walk. Consumed by scope query files to classify nodes without re-deriving the information via full-graph traversals.
    package let scopeAnnotation: ScopeAnnotation

    /// Returns a copy with the node kind replaced. All other fields carry forward from `self`.
    func with(kind: ChoiceGraphNodeKind) -> ChoiceGraphNode {
        ChoiceGraphNode(
            id: id,
            kind: kind,
            positionRange: positionRange,
            children: children,
            parent: parent,
            choicePath: choicePath,
            scopeAnnotation: scopeAnnotation
        )
    }
}

// MARK: - Node Kind

/// Classifies a node in the ``ChoiceGraph`` by the value-structural operation it represents.
///
/// Six kinds correspond to the structural cases that produce or compose values. Operational cases (`contramap`, `prune`, `getSize`, `resize`, `filter`, `classify`, `unique`) and forward-only transforms (`.map`, `.metamorphic`) are not represented — they are interpreter concerns. `just` is a visible constant leaf so that constant elements inside sequences are reachable by the removal encoder.
///
/// ## chooseBits Leaf node producing a single value. Carries ``TypeTag``, valid range, and the current ``ChoiceValue`` from the ``ChoiceSequence``. Addressable unit for value redistribution.
///
/// ## pick Branch selector with one containment edge per possible branch. The active branch has a populated subtree from the current counterexample. Inactive branches have full structural information (from `materializePicks`) but nil position ranges — they are atomic pivot/promotion targets, not reducible within. Pick nodes are the source of self-similarity edges.
///
/// ## bind Dependency node with two children: inner (value-producing) and bound (structure depends on inner). The bound subtree is a dynamic region rebuilt when the inner value changes (unless structurally constant).
///
/// ## zip Parallel composition. Children are structurally independent — no ordering constraint. Defines the independence structure for antichain computation.
///
/// ## sequence Dynamic element children with an optional length constraint. The element count depends on the current counterexample. The materializer derives actual length from element count, not from the length generator's output.
///
/// ## just Constant leaf with no value choices — corresponds to `.pure` in the Freer Monad. Position range covers its single sequence entry. No metadata needed. Treated like `chooseBits` for dependency-edge purposes (no edges) but excluded from leaf-position and value-minimisation passes.
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

/// Pre-computed scope properties derivable during the ``ChoiceGraphBuilder`` tree walk.
///
/// These properties are consumed by scope query files (``MinimizationQuery``, ``ExchangeQuery``, ``ReorderingQuery``) to classify leaves without re-deriving the information via full-graph traversals. Each field replaces a specific ``QueryHelpers`` computation that previously required an O(N) walk of the assembled graph.
///
/// Two orthogonal axes: ``bindRole`` determines whether a node is inside a bind's inner subtree (and if so, which bind controls it), while ``controlKind`` classifies special-purpose leaves that are excluded from most encoder operations.
package struct ScopeAnnotation {
    package let bindRole: BindRole
    package let controlKind: ControlKind

    static let `default` = ScopeAnnotation(bindRole: .independent, controlKind: .standard)

    package var isBindInner: Bool {
        if case .bindInner = bindRole { true } else { false }
    }

    package var controllingBindNodeID: Int? {
        if case let .bindInner(nodeID, _) = bindRole { nodeID } else { nil }
    }

    package var controllingBindDepth: Int? {
        if case let .bindInner(_, depth) = bindRole { depth } else { nil }
    }

    package var isDepthControl: Bool {
        if case .depthControl = controlKind { true } else { false }
    }

    package var isLaneControl: Bool {
        if case .laneControl = controlKind { true } else { false }
    }
}

/// Whether a node is inside a bind's inner subtree.
package enum BindRole {
    /// Not inside any bind's inner subtree.
    case independent
    /// Inside a bind's inner subtree. Any mutation of this leaf triggers a bound subtree rebuild. Outermost-wins semantics: when binds are nested, descendant leaves are claimed by the outermost enclosing bind, matching the reshape cost that the scheduler must account for.
    case bindInner(controllingNodeID: Int, depth: Int)
}

/// Special-purpose leaf classification for leaves excluded from most encoder operations.
package enum ControlKind {
    /// A regular leaf participating in all encoder operations.
    case standard
    /// A ``TypeTag/depthControl`` chooseBits leaf. Recursive depth markers excluded from lockstep, redistribution, swap, reorder, and composed downstream operations.
    case depthControl
    /// A ``TypeTag/laneControl`` chooseBits leaf. Concurrent scheduling markers excluded from the same operations as depth-control leaves. A dedicated lane-collapse encoder handles them separately.
    case laneControl
}

/// Metadata for a ``ChoiceGraphNodeKind/chooseBits(_:)`` leaf node.
package struct ChooseBitsMetadata {
    /// Semantic type of the value.
    package let typeTag: TypeTag

    /// Valid bit-pattern range from the generator, or nil if unconstrained.
    package let validRange: ClosedRange<UInt64>?

    /// Whether the range was user-specified or derived from size scaling.
    package let isRangeExplicit: Bool

    /// Current value from the ``ChoiceSequence``.
    package let value: ChoiceValue
}

/// Metadata for a ``ChoiceGraphNodeKind/pick(_:)`` branch selector node.
package struct PickMetadata {
    /// Pick site fingerprint. Two picks with matching values belong to the same recursive generator (possibly at different depths).
    package let fingerprint: UInt64

    /// The number of branches at this pick site. Branch identifiers are `0 ..< branchCount`.
    package let branchCount: UInt64

    /// Currently selected branch identifier.
    package let selectedID: UInt64

    /// Index into the parent node's ``ChoiceGraphNode/children`` identifying the active branch child.
    package let selectedChildIndex: Int

    /// Per-branch tree elements at this pick site, in the same order as the parent ``ChoiceGraphNode/children``. Each entry is the original `.branch(...)` element (with `isSelected: true` for the active branch) as it existed in the tree at graph construction time. The graph stores these so that ``GraphStructuralEncoder`` can enumerate branch alternatives without reading from the live tree, which may have been stripped by ``Materializer`` calls with `materializePicks: false`.
    package let branchElements: [ChoiceTree]
}

/// Metadata for a ``ChoiceGraphNodeKind/bind(_:)`` dependency node.
package struct BindMetadata {
    /// Stable hash of the originating `.bind` source location, carried through from ``ReflectiveOperation/transform(kind:inner:)`` (via ``ChoiceTree/bind(fingerprint:inner:bound:)``) to identify this bind site across graph rebuilds. Used by ``ChoiceGraph/bindClassifications`` to cache the classification verdict — the same source location always produces the same closure shape, so the verdict is invariant under graph rebuilds.
    package let fingerprint: UInt64

    /// Whether the bound subtree contains no nested binds or picks, meaning the inner value controls ranges and counts but not tree shape.
    package let isStructurallyConstant: Bool

    /// Nesting depth of enclosing bind regions.
    package let bindDepth: Int

    /// Index into the parent node's ``ChoiceGraphNode/children`` identifying the inner (controlling) child.
    package let innerChildIndex: Int

    /// Index into the parent node's ``ChoiceGraphNode/children`` identifying the bound (controlled) child.
    package let boundChildIndex: Int

    /// Structural path from the ``ChoiceTree`` root at graph-construction time to this bind. Used by ``ChoiceGraph/extractBoundSubtree(from:matchingPath:)`` to locate the matching bind in a post-mutation freshTree. The root bind has the empty path.
    package let bindPath: BindPath

    /// Cached classification recorded by ``ChoiceGraph/classifyBind(at:gen:scope:upstreamLeafNodeID:)``. Nil until the bind is classified, or after a reshape clears the prior result. Read by the scheduler before dispatching expensive dependent-node encoders (for example ``GraphComposedEncoder``) so unsuitable sites are skipped immediately.
    package var classification: BindClassification?

    /// Creates bind metadata with the given structural properties and optional cached classification.
    package init(
        fingerprint: UInt64,
        isStructurallyConstant: Bool,
        bindDepth: Int,
        innerChildIndex: Int,
        boundChildIndex: Int,
        bindPath: BindPath,
        classification: BindClassification? = nil
    ) {
        self.fingerprint = fingerprint
        self.isStructurallyConstant = isStructurallyConstant
        self.bindDepth = bindDepth
        self.innerChildIndex = innerChildIndex
        self.boundChildIndex = boundChildIndex
        self.bindPath = bindPath
        self.classification = classification
    }
}

/// Metadata for a ``ChoiceGraphNodeKind/zip(_:)`` parallel composition node.
package struct ZipMetadata {
    /// When true, coverage analysis skips this subtree.
    package let isOpaque: Bool
}

/// Metadata for a ``ChoiceGraphNodeKind/sequence(_:)`` node.
package struct SequenceMetadata {
    /// Explicit length range from ``ChoiceMetadata``, if any. Constrains deletion — the reducer cannot delete below the lower bound. This is metadata on the node, not a containment edge to a child.
    package let lengthConstraint: ClosedRange<UInt64>?

    /// Current element count from the ``ChoiceSequence``.
    package let elementCount: Int

    /// Full ``ChoiceSequence`` extent of each direct child element, including any transparent wrapper markers (group/bind from getSize-bind, transform-bind, and so on). Indexed parallel to ``ChoiceGraphNode/children``. Per-element removal must delete the full extent — removing only the inner chooseBits position leaves orphan markers that the materializer cannot decode.
    package let childPositionRanges: [ClosedRange<Int>]

    /// Maps child node ID to its index in ``childPositionRanges`` and ``ChoiceGraphNode/children``. O(1) lookup replacing linear `firstIndex(of:)` scans.
    package let childIndexByNodeID: [Int: Int]

    /// Common ``TypeTag`` of all elements when the sequence is type-homogeneous, or nil for heterogeneous or empty sequences.
    ///
    /// Derived bottom-up at graph construction time from two cases:
    /// - Direct: all children are ``ChoiceGraphNodeKind/chooseBits(_:)`` with the same tag.
    /// - Nested: all children are ``ChoiceGraphNodeKind/sequence(_:)`` with the same non-nil ``elementTypeTag``, implying subsequence homogeneity.
    ///
    /// When non-nil, any two leaves within the sequence are type-compatible for redistribution without materializing pairwise edges. The exchange scope builder uses this to construct ``RedistributionPair`` descriptors in O(1) per sequence instead of O(C^2) per sequence.
    package let elementTypeTag: TypeTag?
}
