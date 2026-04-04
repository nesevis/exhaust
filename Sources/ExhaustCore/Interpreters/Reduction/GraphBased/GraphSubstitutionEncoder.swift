//
//  GraphSubstitutionEncoder.swift
//  Exhaust
//

// MARK: - Graph Substitution Encoder

/// Splices donor subtrees along self-similarity edges to reduce structural size or achieve shortlex improvement.
///
/// For each self-similarity edge, splices the donor's sequence entries into the target's position range. Candidates with positive size delta (structural reduction) are tried first, sorted by delta descending. Same-size edges (delta == 0) are included as cross-group promotion candidates — a different branch selection at the same size may be shortlex-simpler. The scheduler re-materializes each candidate through ``SequenceDecoder`` to produce a structurally valid tree.
///
/// This is the graph-based counterpart of ``BindSubstitutionEncoder`` and subsumes the cross-group promotion strategy from ``BranchSimplificationEncoder``. The graph provides self-similarity edges with position ranges directly, eliminating both the linear scan over bind regions and the fragile subsequence-matching position lookup.
///
/// - SeeAlso: ``BindSubstitutionEncoder``, ``SelfSimilarityEdge``
public struct GraphSubstitutionEncoder: GraphEncoder {
    public let name: EncoderName = .graphSubstitution

    // MARK: - State

    private var candidates: [ChoiceSequence] = []
    private var candidateIndex = 0

    // MARK: - GraphEncoder

    public mutating func start(
        graph: ChoiceGraph,
        sequence: ChoiceSequence,
        tree: ChoiceTree
    ) {
        candidateIndex = 0
        candidates = []

        // Build substitution candidates from self-similarity edges.
        // Positive delta: structural reduction (donor smaller than target).
        // Zero delta: cross-group promotion (same size, different branch selection).
        // Both directions are tried for each edge.
        var edgesWithDelta: [(targetNodeID: Int, donorNodeID: Int, sizeDelta: Int)] = []
        for edge in graph.selfSimilarityEdges {
            if edge.sizeDelta > 0 {
                edgesWithDelta.append((edge.nodeA, edge.nodeB, edge.sizeDelta))
            } else if edge.sizeDelta < 0 {
                edgesWithDelta.append((edge.nodeB, edge.nodeA, -edge.sizeDelta))
            } else {
                // Same-size: try both directions for shortlex improvement.
                edgesWithDelta.append((edge.nodeA, edge.nodeB, 0))
                edgesWithDelta.append((edge.nodeB, edge.nodeA, 0))
            }
        }

        // Sort by size delta descending — largest structural reduction first,
        // same-size promotions last.
        edgesWithDelta.sort { $0.sizeDelta > $1.sizeDelta }

        for (targetNodeID, donorNodeID, _) in edgesWithDelta {
            let targetNode = graph.nodes[targetNodeID]
            let donorNode = graph.nodes[donorNodeID]
            guard let targetRange = targetNode.positionRange,
                  let donorRange = donorNode.positionRange
            else { continue }

            // Splice: replace target's sequence entries with donor's sequence entries.
            let donorEntries = Array(sequence[donorRange.lowerBound ... donorRange.upperBound])
            var candidate = sequence
            candidate.replaceSubrange(
                targetRange.lowerBound ... targetRange.upperBound,
                with: donorEntries
            )

            if sequence.shortLexPrecedes(candidate) == false {
                candidates.append(candidate)
            }
        }
    }

    public mutating func nextProbe(lastAccepted _: Bool) -> ChoiceSequence? {
        guard candidateIndex < candidates.count else { return nil }
        let candidate = candidates[candidateIndex]
        candidateIndex += 1
        return candidate
    }

}
