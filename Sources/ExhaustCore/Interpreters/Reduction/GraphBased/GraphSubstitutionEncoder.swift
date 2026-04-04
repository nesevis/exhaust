//
//  GraphSubstitutionEncoder.swift
//  Exhaust
//

// MARK: - Graph Substitution Encoder

/// Splices donor subtrees along self-similarity edges to reduce structural depth.
///
/// For each self-similarity edge where the donor is smaller than the target (positive size delta), replaces the target pick node's branch group with the donor's branch group in the tree, then flattens to a candidate sequence. Candidates are sorted by size delta descending — largest reduction first.
///
/// This is the graph-based counterpart of ``BindSubstitutionEncoder``. The graph provides self-similarity edges directly, eliminating the linear scan over bind regions.
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

        // Collect all pick nodes with their tree fingerprints.
        var pickFingerprints: [UInt64: [Fingerprint]] = [:]
        for element in tree.walk() {
            guard case let .group(array, _) = element.node,
                  array.contains(where: \.unwrapped.isBranch),
                  array.contains(where: \.isSelected)
            else { continue }

            if let maskedID = selectedBranchMaskedSiteID(of: element.node) {
                pickFingerprints[maskedID, default: []].append(element.fingerprint)
            }
        }

        // Build a position-to-fingerprint map for pick nodes.
        var positionToFingerprint: [Int: Fingerprint] = [:]
        for element in tree.walk() {
            guard case let .group(array, _) = element.node,
                  array.contains(where: \.unwrapped.isBranch),
                  array.contains(where: \.isSelected)
            else { continue }

            // Use the flattened position range to map graph nodes to tree fingerprints.
            let elementSequence = ChoiceSequence.flatten(element.node)
            if elementSequence.isEmpty == false {
                // Find this node's starting position in the full sequence.
                if let pos = findPosition(of: elementSequence, in: sequence) {
                    positionToFingerprint[pos] = element.fingerprint
                }
            }
        }

        // For each self-similarity edge with positive size delta, build substitution candidates.
        var edgesWithDelta: [(targetNodeID: Int, donorNodeID: Int, sizeDelta: Int)] = []
        for edge in graph.selfSimilarityEdges {
            if edge.sizeDelta > 0 {
                // nodeA is larger (target), nodeB is smaller (donor).
                edgesWithDelta.append((edge.nodeA, edge.nodeB, edge.sizeDelta))
            } else if edge.sizeDelta < 0 {
                // nodeB is larger (target), nodeA is smaller (donor).
                edgesWithDelta.append((edge.nodeB, edge.nodeA, -edge.sizeDelta))
            }
        }

        // Sort by size delta descending — largest reduction first.
        edgesWithDelta.sort { $0.sizeDelta > $1.sizeDelta }

        for (targetNodeID, donorNodeID, _) in edgesWithDelta {
            let targetNode = graph.nodes[targetNodeID]
            let donorNode = graph.nodes[donorNodeID]
            guard let targetRange = targetNode.positionRange,
                  let donorRange = donorNode.positionRange
            else { continue }

            // Find tree fingerprints for target and donor.
            guard let targetFingerprint = positionToFingerprint[targetRange.lowerBound],
                  let donorFingerprint = positionToFingerprint[donorRange.lowerBound]
            else { continue }

            // Replace target's subtree with donor's subtree in the tree.
            let donorSubtree = tree[donorFingerprint]
            var candidateTree = tree
            candidateTree[targetFingerprint] = donorSubtree
            let candidateSequence = ChoiceSequence.flatten(candidateTree)

            if sequence.shortLexPrecedes(candidateSequence) == false {
                candidates.append(candidateSequence)
            }
        }
    }

    public mutating func nextProbe(lastAccepted _: Bool) -> ChoiceSequence? {
        guard candidateIndex < candidates.count else { return nil }
        let candidate = candidates[candidateIndex]
        candidateIndex += 1
        return candidate
    }

    // MARK: - Helpers

    /// Finds the starting position of a subsequence within the full sequence by scanning for a matching prefix.
    private func findPosition(
        of needle: ChoiceSequence,
        in haystack: ChoiceSequence
    ) -> Int? {
        guard needle.isEmpty == false else { return nil }
        let first = needle[0]
        var position = 0
        while position < haystack.count {
            if haystack[position] == first {
                // Verify the rest matches.
                var matches = true
                var offset = 1
                while offset < needle.count, position + offset < haystack.count {
                    if haystack[position + offset] != needle[offset] {
                        matches = false
                        break
                    }
                    offset += 1
                }
                if matches, offset == needle.count {
                    return position
                }
            }
            position += 1
        }
        return nil
    }
}

// MARK: - Helpers

private func selectedBranchMaskedSiteID(of group: ChoiceTree) -> UInt64? {
    guard case let .group(array, _) = group else { return nil }
    guard let selected = array.first(where: \.isSelected) else { return nil }
    return selected.unwrapped.depthMaskedSiteID
}
