/// Adds candidate-specific feasibility checks to exact decoding. Only ``SequenceDecoder/exact(materializePicks:admission:)`` carries one, so guided decoding cannot silently drop it.
enum DecoderAdmission {
    case standard
    case numericPair(NumericPair)
    case numericJoint([ReductionLeaf])

    /// Whether the admission inspects the decoded history. Only exact decoding produces a history to inspect, and only then does value-only decoding need to build it.
    var inspectsDecodedHistory: Bool {
        switch self {
            case .standard:
                false
            case .numericPair, .numericJoint:
                true
        }
    }

    /// Requires every numeric edit to survive decoding verbatim and improve the checkpoint, so a clamped edit never reaches the property.
    ///
    /// Equality compares choices and markers, not range metadata. Fresh bounds can change while all requested edits and every structural marker remain intact.
    func admits(decoded: ChoiceSequence, candidate: ChoiceSequence, original: ChoiceSequence) -> Bool {
        switch self {
            case .standard:
                true
            case .numericPair, .numericJoint:
                decoded == candidate && decoded.shortLexPrecedes(original)
        }
    }

    /// Rejects a surviving failure when dependent generators moved an edited leaf to a different bind site.
    func admits(tree: ChoiceTree) -> Bool {
        switch self {
            case .standard:
                true
            case let .numericPair(pair):
                Self.preservesIdentity(of: [pair.source, pair.sink], in: tree)
            case let .numericJoint(leaves):
                Self.preservesIdentity(of: leaves, in: tree)
        }
    }
}

private extension DecoderAdmission {
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
                  metadata.supportsNumericSearch
            else {
                return false
            }
        }
        return true
    }
}
