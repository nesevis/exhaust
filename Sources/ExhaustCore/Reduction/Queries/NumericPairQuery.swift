/// Selects stalled numeric sources without requiring their compensating partners to have converged.
///
/// Preparation is bounded separately from property probes. Bind metadata admits supported stable paths; materialization still has to preserve the complete proposed choice sequence.
enum NumericPairQuery {
    static let maximumLeaves = 256
    static let maximumPairs = 30

    /// A stalled source that the search moves toward its target, and the partner whose value may move in either direction to keep the property failing.
    struct Pair: Equatable {
        let source: ReductionLeaf
        let sink: ReductionLeaf
    }

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

    /// Boolean generators use UInt8 in 0...1; exclude that domain, including numeric generators with the same representation.
    static func isNumeric(_ metadata: ChooseBitsMetadata) -> Bool {
        guard metadata.typeTag != .uint8 || metadata.validRange != 0 ... 1 else {
            return false
        }
        switch metadata.typeTag {
            case .int, .int8, .int16, .int32, .int64, .uint, .uint8, .uint16, .uint32, .uint64:
                return true
            case .float, .float16, .double:
                return metadata.value.decodedDoubleValue.isFinite
            case .date, .bits, .character, .depthControl, .laneControl:
                return false
        }
    }

    /// Checks bind-site continuity even when different dependent generators happen to emit identical flat markers.
    static func preservesIdentity(of pair: Pair, in tree: ChoiceTree) -> Bool {
        preservesIdentity(of: [pair.source, pair.sink], in: tree)
    }

    /// Checks all joint edits against fresh bind ancestry using one graph construction per surviving failure.
    static func preservesIdentity(of leaves: [ReductionLeaf], in tree: ChoiceTree) -> Bool {
        guard leaves.contains(where: { $0.bindFingerprints.isEmpty == false }) else {
            return true
        }
        let graph = ChoiceGraph.build(from: tree)
        for leaf in leaves {
            guard let nodeID = graph.leafNodes.first(where: { graph.nodes[$0].positionRange?.lowerBound == leaf.position }),
                  graph.nodes[nodeID].choicePath == leaf.path,
                  bindFingerprints(above: nodeID, graph: graph) == leaf.bindFingerprints,
                  case let .chooseBits(metadata) = graph.nodes[nodeID].kind,
                  isNumeric(metadata)
            else {
                return false
            }
        }
        return true
    }

    private static func bindFingerprints(above nodeID: Int, graph: ChoiceGraph) -> [UInt64] {
        var fingerprints: [UInt64] = []
        var ancestor = graph.nodes[nodeID].parent
        while let ancestorID = ancestor {
            let node = graph.nodes[ancestorID]
            if case let .bind(metadata) = node.kind {
                fingerprints.append(metadata.fingerprint)
            }
            ancestor = node.parent
        }
        return fingerprints
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
