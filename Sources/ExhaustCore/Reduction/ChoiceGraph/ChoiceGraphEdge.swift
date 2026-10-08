//
//  ChoiceGraphEdge.swift
//  Exhaust
//

// MARK: - Dependency Edge

/// Directed edge from a bind-inner node to a node within its bound subtree.
///
/// The bound content's structure is contingent on the bind-inner value. Reduction must be ordered — parent before child. A change upstream invalidates everything downstream. Topological sort and reachability computation operate on this edge layer.
package struct DependencyEdge: Equatable, Sendable {
    /// Node ID of the bind-inner (controlling) node.
    package let source: Int

    /// Node ID of a node within the bound subtree (controlled).
    package let target: Int
}

// MARK: - Containment Edge

/// Directed edge from a parent node to a child in the containment tree.
///
/// Connects zip → children, sequence → elements, pick → branches (active and inactive), bind → inner and bound. The direction is hierarchical (parent → child) but carries no dependency semantics — siblings are structurally independent. Deletion traversal uses nesting to prune descendants of removed elements.
package struct ContainmentEdge: Equatable, Sendable {
    /// Node ID of the parent.
    package let source: Int

    /// Node ID of the child.
    package let target: Int
}

// MARK: - Type-Compatibility Edge

/// Connects value leaves in one sequence-sibling or zip cross-slot decision context.
///
/// Cross-type pairs are eligible for rational redistribution as well as same-type pairs. Bind-role and control-leaf restrictions are applied by ``GeneratedRedistributionPairCursor`` after compatibility enumeration.
package struct TypeCompatibilityEdge: Equatable, Sendable {
    /// Node ID of one endpoint.
    package let nodeA: Int

    /// Node ID of the other endpoint.
    package let nodeB: Int

    /// The endpoints' shared ``TypeTag``, or nil when rational redistribution must bridge different types.
    package let typeTag: TypeTag?
}
