/// Checks that numeric edits still address the same generator sites after replay. Decoder admission calls this only after a candidate survives the property check.
enum NumericRecoveryCheck {
    /// Checks bind-site continuity even when different dependent generators happen to emit identical flat markers.
    static func preservesIdentity(of pair: NumericPair, in tree: ChoiceTree) -> Bool {
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
                  ReductionLeaf.bindFingerprints(above: nodeID, graph: graph) == leaf.bindFingerprints,
                  case let .chooseBits(metadata) = graph.nodes[nodeID].kind,
                  ReductionLeaf.supportsNumericSearch(metadata)
            else {
                return false
            }
        }
        return true
    }
}
