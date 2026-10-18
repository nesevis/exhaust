//
//  DepthCollapseQuery.swift
//  Exhaust
//

/// Builds minimization scopes containing only ``TypeTag/depthControl`` chooseBits leaves.
///
/// A depth-control leaf is the layer index a recursive generator draws before building its body: the inner of the `._bound` that ``Gen/recursive(base:depthRange:extend:)`` and ``Gen/unfold(seed:depthRange:step:finish:)`` end in. Lowering one drops layers, and the materializer rebuilds the bound subtree at the new depth, carrying the surviving prefix values across.
///
/// ## Strategy
///
/// One scope per leaf, each carrying a single leaf, searched toward the range floor. Single-leaf scopes because an accepted step reshapes the subtree that layer governs, which renumbers every node below it: a second leaf in the same scope would be addressing a graph that no longer exists. The scheduler rebuilds between dispatches and the next scope is built against the fresh graph.
///
/// The search is a binary search rather than a probe at the floor. The floor is rarely failing on its own (a property that needs three elements still passes at depth one), so a single probe would report the leaf immovable and stop. Binary search over the distance finds the smallest failing depth in a logarithmic number of probes.
///
/// ## Relationship to Other Queries
///
/// ``MinimizationQuery``, ``ExchangeQuery``, ``PermutationQuery`` and ``ReorderingQuery`` all exclude depth-control leaves via ``ScopeAnnotation/isDepthControl``, and that exclusion is right for them: those operations move a value to another site, and a layer index read at another site is a number unrelated to that site's domain rather than an out-of-range one a clamp could correct. This query is the complement. It never moves a value between sites, so the objection does not apply.
///
/// A depth-control leaf is also the inner of a bind, so ``MinimizationQuery`` builds a ``MinimizationScope/boundValue(_:)`` scope for the same site. That route is gated on the bind classifying as ``BindTopology/identical`` and a depth change is by definition ``BindTopology/divergent``, so it is always skipped as fruitless. The two never compete.
enum DepthCollapseQuery {
    /// One scope per live depth-control leaf that has not reached its floor, deepest first. Empty when the graph holds no depth control, which is every generator that does not recurse.
    static func build(graph: ChoiceGraph) -> [MinimizationScope] {
        var candidates: [(distance: UInt64, position: Int, scope: MinimizationScope)] = []

        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else { continue }
            guard node.scopeAnnotation.isDepthControl else { continue }
            guard let positionRange = node.positionRange else { continue }

            let current = metadata.value.bitPattern64
            let floor = metadata.value.reductionTarget(in: metadata.validRange)
            guard current != floor else { continue }

            if let converged = graph.convergenceStore[nodeID], converged.bound == current {
                continue
            }

            candidates.append((
                distance: current > floor ? current - floor : floor - current,
                position: positionRange.lowerBound,
                scope: .depthCollapse(ValueMinimizationScope(
                    leaves: [LeafEntry(nodeID: nodeID)],
                    batchZeroEligible: false
                ))
            ))
        }

        // Deepest first: the outermost depth governs the most layers, and collapsing it can remove inner depth leaves outright.
        candidates.sort { left, right in
            left.distance == right.distance
                ? left.position < right.position
                : left.distance > right.distance
        }
        return candidates.map(\.scope)
    }

    /// How far the scope's leaf sits above its floor, which is how many layers an accepted collapse can remove.
    static func distanceToFloor(of scope: MinimizationScope, graph: ChoiceGraph) -> Int {
        guard let nodeID = leafNodeID(of: scope),
              case let .chooseBits(metadata) = graph.nodes[nodeID].kind
        else {
            return 0
        }
        let current = metadata.value.bitPattern64
        let floor = metadata.value.reductionTarget(in: metadata.validRange)
        let distance = current > floor ? current - floor : floor - current
        return Int(min(distance, UInt64(Int.max)))
    }

    /// The binary search's step count over the leaf's distance to its floor, at least one.
    static func estimatedProbes(of scope: MinimizationScope, graph: ChoiceGraph) -> Int {
        let distance = distanceToFloor(of: scope, graph: graph)
        guard distance > 1 else { return 1 }
        return Int.bitWidth - distance.leadingZeroBitCount
    }

    // MARK: - Private Helpers

    private static func leafNodeID(of scope: MinimizationScope) -> Int? {
        guard case let .depthCollapse(valueScope) = scope else { return nil }
        return valueScope.leaves.first?.nodeID
    }
}
