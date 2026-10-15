//
//  NumericPairQuery+Shared.swift
//  Exhaust
//

// MARK: - Numeric Pair Identity

/// Identity checks decoder admission applies to a decoded pair: the pair is admissible only when both leaves keep their position, path, and bind ancestry.
extension NumericPairQuery {
    /// A stalled source that the search moves toward its target, and the partner whose value may move in either direction to keep the property failing.
    struct Pair: Equatable {
        let source: ReductionLeaf
        let sink: ReductionLeaf
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

    static func bindFingerprints(above nodeID: Int, graph: ChoiceGraph) -> [UInt64] {
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
}
