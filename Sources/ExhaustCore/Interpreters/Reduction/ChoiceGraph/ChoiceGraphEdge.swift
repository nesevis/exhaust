//
//  ChoiceGraphEdge.swift
//  Exhaust
//

// MARK: - Dependency Edge

/// Directed edge from a bind-inner node to a node within its bound subtree.
///
/// The bound content's structure is contingent on the bind-inner value. Reduction must be ordered — parent before child. A change upstream invalidates everything downstream. Topological sort and reachability computation operate on this edge layer.
public struct DependencyEdge: Equatable {
    /// Node ID of the bind-inner (controlling) node.
    public let source: Int

    /// Node ID of a node within the bound subtree (controlled).
    public let target: Int
}

// MARK: - Containment Edge

/// Directed edge from a parent node to a child in the containment tree.
///
/// Connects zip → children, sequence → elements, pick → branches (active and inactive), bind → inner and bound. The direction is hierarchical (parent → child) but carries no dependency semantics — siblings are structurally independent. The containment layer defines the independence structure for antichain computation.
public struct ContainmentEdge: Equatable {
    /// Node ID of the parent.
    public let source: Int

    /// Node ID of the child.
    public let target: Int
}

// MARK: - Self-Similarity Edge

/// Undirected edge between two active pick nodes with matching `fingerprint`.
///
/// These picks belong to the same recursive generator at different depths and are structurally exchangeable. The size delta determines substitution direction: a positive delta means the neighbour is smaller (the source is the substitution target, the neighbour is the donor).
public struct SelfSimilarityEdge: Equatable {
    /// Node ID of one pick node.
    public let nodeA: Int

    /// Node ID of the other pick node.
    public let nodeB: Int

    /// Subtree size of nodeA minus subtree size of nodeB. Positive means nodeB is smaller (nodeA is the substitution target).
    public let sizeDelta: Int
}

// MARK: - Type-Compatibility Edge

/// Undirected edge between two nodes in the same antichain with compatible types.
///
/// Connects `chooseBits` leaves with matching ``TypeTag``, or `sequence` nodes with matching element generator identity. The edge itself is structurally stable — it changes only when the antichain changes. Source/sink annotations are dynamic and updated on any acceptance.
public struct TypeCompatibilityEdge: Equatable {
    /// Node ID of one endpoint.
    public let nodeA: Int

    /// Node ID of the other endpoint.
    public let nodeB: Int

    /// The shared ``TypeTag`` that makes these nodes compatible, or nil for sequence-to-sequence edges matched by element generator identity.
    public let typeTag: TypeTag?
}

// MARK: - Source/Sink Status

/// Redistribution role of a leaf node based on its current value.
///
/// Updated on any acceptance (structural or value). A non-zero leaf is a source (can donate magnitude); a zero-valued leaf is a sink (can absorb).
public enum SourceSinkStatus {
    /// Non-zero value — can donate magnitude to a type-compatible sink.
    case source

    /// Zero or semantic-simplest value — can absorb magnitude from a type-compatible source.
    case sink
}
