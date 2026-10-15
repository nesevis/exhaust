/// Selects stalled numeric sources without requiring their compensating partners to have converged.
///
/// Preparation is bounded separately from property probes. Bind metadata admits supported stable paths; materialization still has to preserve the complete proposed choice sequence.
enum NumericPairQuery {
    static let maximumLeaves = 256
    static let maximumPairs = 30

    /// Collects the bounded search scope, interleaving each source's nearest and farthest partners before any intermediate distance.
    static func build(graph: ChoiceGraph, gate: BoundValueGate) -> [Pair] {
        var pairs: [Pair] = []
        let leaves = eligibleLeaves(graph: graph)
        guard leaves.count > 1 else {
            return []
        }
        let sourceIndices = leaves.indices.filter { isStalled(leaves[$0], graph: graph, gate: gate) }
        // Each source's nearest and farthest partners come first, alternating source by source, so neither distance class can take the whole cap.
        let lastIndex = leaves.count - 1
        let rounds = [[1, lastIndex]] + stride(from: 2, to: lastIndex, by: 1).map { [$0] }
        var seen: Set<Int> = []
        for offsets in rounds {
            for sourceIndex in sourceIndices {
                for offset in offsets {
                    let sinkIndex = min(sourceIndex + offset, lastIndex)
                    guard sinkIndex > sourceIndex,
                          seen.insert(sourceIndex * maximumLeaves + sinkIndex).inserted
                    else {
                        continue
                    }
                    pairs.append(Pair(source: leaves[sourceIndex], sink: leaves[sinkIndex]))
                    if pairs.count == maximumPairs {
                        return pairs
                    }
                }
            }
        }
        return pairs
    }

    /// Shares numeric and bind admission between pair search and higher-order group discovery.
    static func eligibleLeaves(graph: ChoiceGraph) -> [ReductionLeaf] {
        // Filter before capping, so non-numeric leaves (a long string's characters, say) cannot use up the cap ahead of numeric ones.
        graph.leafNodes.lazy.compactMap { nodeID -> ReductionLeaf? in
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind,
                  let position = node.positionRange?.lowerBound,
                  isNumeric(metadata),
                  supportsBinds(above: nodeID, graph: graph)
            else {
                return nil
            }
            return ReductionLeaf(
                nodeID: nodeID,
                position: position,
                path: node.choicePath,
                choice: metadata.value,
                range: metadata.validRange ?? metadata.typeTag.bitPatternRange,
                bindFingerprints: bindFingerprints(above: nodeID, graph: graph),
                mayReshapeOnAcceptance: node.scopeAnnotation.isBindInner
            )
        }.prefix(maximumLeaves).sorted { $0.position < $1.position }
    }

    /// Requires a current convergence floor above target, or a fruitless bound search for a bind inner.
    static func isStalled(_ leaf: ReductionLeaf, graph: ChoiceGraph, gate: BoundValueGate) -> Bool {
        guard leaf.choice.bitPattern64 != leaf.choice.reductionTarget(in: leaf.range) else {
            return false
        }
        return graph.convergenceStore[leaf.nodeID]?.bound == leaf.choice.bitPattern64
            || (graph.nodes[leaf.nodeID].scopeAnnotation.isBindInner
                && ChoiceGraphScheduler.isStalledBindInner(bindInnerLeafNodeID: leaf.nodeID, graph: graph, gate: gate))
    }

    /// Unknown or divergent bind shapes are deferred; the existing classifier's cached verdict avoids speculative endpoint work here.
    private static func supportsBinds(above nodeID: Int, graph: ChoiceGraph) -> Bool {
        var ancestor = graph.nodes[nodeID].parent
        while let ancestorID = ancestor {
            let node = graph.nodes[ancestorID]
            if case let .bind(metadata) = node.kind, metadata.isStructurallyConstant == false {
                let classification = metadata.classification ?? graph.bindClassifications[metadata.fingerprint]
                guard classification?.topology == .identical, classification?.liftability == .both else {
                    return false
                }
            }
            ancestor = node.parent
        }
        return true
    }
}
