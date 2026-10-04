/// Selects stalled numeric sources without requiring their compensating partners to have converged.
///
/// Preparation is bounded separately from property probes. Bind metadata admits supported stable paths; materialization still has to preserve the complete proposed choice sequence.
enum NumericPairQuery {
    static let maximumLeaves = 256
    static let maximumPairs = 30

    /// Captures the domain as well as the address so exhausted work becomes eligible again after a domain change.
    struct Leaf: Equatable {
        let nodeID: Int
        let position: Int
        let path: ChoicePath
        let choice: ChoiceValue
        let range: ClosedRange<UInt64>
        let bindFingerprints: [UInt64]
        /// Mirrors ``LeafEntry/mayReshapeOnAcceptance``: only a bind inner's edit can make the graph's dependent ranges stale, so every other edit is written in place.
        let mayReshapeOnAcceptance: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.position == rhs.position && lhs.path == rhs.path && lhs.choice == rhs.choice
                && lhs.range == rhs.range && lhs.bindFingerprints == rhs.bindFingerprints
        }
    }

    /// A stalled source that the search moves toward its target, and the partner whose value may move in either direction to keep the property failing.
    struct Pair: Equatable {
        let source: Leaf
        let sink: Leaf
    }

    /// Collects the bounded search scope, interleaving each source's nearest and farthest partners before any intermediate distance.
    static func build(graph: ChoiceGraph, gate: BoundValueGate) -> [Pair] {
        var pairs: [Pair] = []
        // Filter before capping, so non-numeric leaves (a long string's characters, say) cannot use up the cap ahead of numeric ones.
        let leaves = graph.leafNodes.lazy.compactMap { nodeID -> Leaf? in
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind,
                  let position = node.positionRange?.lowerBound,
                  isNumeric(metadata),
                  supportsBinds(above: nodeID, graph: graph)
            else {
                return nil
            }
            return Leaf(
                nodeID: nodeID,
                position: position,
                path: node.choicePath,
                choice: metadata.value,
                range: metadata.validRange ?? metadata.typeTag.bitPatternRange,
                bindFingerprints: bindFingerprints(above: nodeID, graph: graph),
                mayReshapeOnAcceptance: node.scopeAnnotation.isBindInner
            )
        }.prefix(maximumLeaves).sorted { $0.position < $1.position }
        guard leaves.count > 1 else {
            return []
        }
        let sourceIndices = leaves.indices.filter { index in
            let leaf = leaves[index]
            guard leaf.choice.bitPattern64 != leaf.choice.reductionTarget(in: leaf.range) else {
                return false
            }
            return graph.convergenceStore[leaf.nodeID]?.bound == leaf.choice.bitPattern64
                || (graph.nodes[leaf.nodeID].scopeAnnotation.isBindInner
                    && ChoiceGraphScheduler.isStalledBindInner(bindInnerLeafNodeID: leaf.nodeID, graph: graph, gate: gate))
        }
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
        guard pair.source.bindFingerprints.isEmpty == false || pair.sink.bindFingerprints.isEmpty == false else {
            return true
        }
        let graph = ChoiceGraph.build(from: tree)
        for leaf in [pair.source, pair.sink] {
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
