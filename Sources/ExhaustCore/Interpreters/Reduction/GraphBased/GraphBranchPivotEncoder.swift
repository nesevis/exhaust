//
//  GraphBranchPivotEncoder.swift
//  Exhaust
//

// MARK: - Graph Branch Pivot Encoder

/// Simplifies branch selections using the graph's pick nodes and self-similarity edges.
///
/// Two strategies, tried in order:
///
/// 1. **Direct descendant promotion:** For each pick node with self-similarity edges, replaces the branch group with a direct descendant branch group from the same recursive generator, collapsing one level of depth.
/// 2. **Pivot:** For each pick node, tries swapping the `.selected` marker to an alternative branch, sorted by shortlex complexity.
///
/// Candidates are pre-computed in ``start(graph:sequence:tree:)`` and yielded via ``nextProbe(lastAccepted:)``.
///
/// - SeeAlso: ``BranchSimplificationEncoder``
public struct GraphBranchPivotEncoder: GraphEncoder {
    public let name: EncoderName = .graphBranchPivot

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

        // Collect pick node IDs from the graph for self-similarity-guided ordering.
        var pickNodeSiteIDs = Set<UInt64>()
        for node in graph.nodes {
            guard case let .pick(metadata) = node.kind,
                  node.positionRange != nil
            else { continue }
            pickNodeSiteIDs.insert(metadata.depthMaskedSiteID)
        }

        // Direct descendant promotion — targets pick sites that have self-similarity edges.
        let promotionCandidates = Self.directDescendantPromotionCandidates(
            tree: tree,
            sequence: sequence,
            pickNodeSiteIDs: pickNodeSiteIDs
        )

        // Pivot — try alternative branches for all pick sites.
        let pivotCandidates = Self.pivotCandidates(tree: tree, sequence: sequence)

        // Promotion first (structural simplification), then pivots.
        candidates = promotionCandidates + pivotCandidates
    }

    public mutating func nextProbe(lastAccepted _: Bool) -> ChoiceSequence? {
        guard candidateIndex < candidates.count else { return nil }
        let candidate = candidates[candidateIndex]
        candidateIndex += 1
        return candidate
    }

    // MARK: - Direct Descendant Promotion

    /// Builds candidates that replace a branch group with one of its direct descendant branch groups from the same recursive generator.
    ///
    /// Prioritises pick sites whose `depthMaskedSiteID` appears in the graph's self-similarity edges (sites where the graph knows recursive structure exists).
    private static func directDescendantPromotionCandidates(
        tree: ChoiceTree,
        sequence: ChoiceSequence,
        pickNodeSiteIDs: Set<UInt64>
    ) -> [ChoiceSequence] {
        guard tree.contains(\.unwrapped.isBranch) else { return [] }

        var candidates: [ChoiceSequence] = []

        for element in tree.walk() {
            guard case let .group(array, _) = element.node,
                  array.contains(where: \.unwrapped.isBranch)
            else { continue }

            let parentMasked = selectedBranchMaskedSiteID(of: element.node)
            guard let parentMasked else { continue }

            // Prioritise sites known to the graph's self-similarity layer.
            guard pickNodeSiteIDs.contains(parentMasked) else { continue }

            guard let selectedBranch = array.first(where: \.isSelected) else { continue }
            let descendants = directDescendantBranchGroups(
                in: selectedBranch.unwrapped,
                matching: parentMasked
            )
            guard descendants.isEmpty == false else { continue }

            for descendant in descendants {
                var candidateTree = tree
                candidateTree[element.fingerprint] = descendant
                let candidateSequence = ChoiceSequence.flatten(candidateTree)
                if sequence.shortLexPrecedes(candidateSequence) == false {
                    candidates.append(candidateSequence)
                }
            }
        }

        candidates.sort { $0.shortLexPrecedes($1) }
        return candidates
    }

    /// Finds direct descendant branch groups within a subtree that share the given `depthMaskedSiteID`.
    private static func directDescendantBranchGroups(
        in subtree: ChoiceTree,
        matching targetMaskedSiteID: UInt64
    ) -> [ChoiceTree] {
        var results: [ChoiceTree] = []
        collectDirectDescendants(
            in: subtree,
            matching: targetMaskedSiteID,
            results: &results
        )
        return results
    }

    private static func collectDirectDescendants(
        in node: ChoiceTree,
        matching targetMaskedSiteID: UInt64,
        results: inout [ChoiceTree]
    ) {
        switch node {
        case let .group(children, _):
            if children.contains(where: \.unwrapped.isBranch) {
                if let maskedID = selectedBranchMaskedSiteID(of: node),
                   maskedID == targetMaskedSiteID
                {
                    results.append(node)
                    return
                }
            }
            for child in children {
                collectDirectDescendants(
                    in: child.unwrapped,
                    matching: targetMaskedSiteID,
                    results: &results
                )
            }
        case let .selected(inner):
            collectDirectDescendants(
                in: inner,
                matching: targetMaskedSiteID,
                results: &results
            )
        case let .bind(_, bound):
            collectDirectDescendants(
                in: bound,
                matching: targetMaskedSiteID,
                results: &results
            )
        case let .branch(_, _, _, _, choice):
            collectDirectDescendants(
                in: choice,
                matching: targetMaskedSiteID,
                results: &results
            )
        case let .sequence(_, elements, _):
            for element in elements {
                collectDirectDescendants(
                    in: element,
                    matching: targetMaskedSiteID,
                    results: &results
                )
            }
        case let .resize(_, choices):
            for choice in choices {
                collectDirectDescendants(
                    in: choice,
                    matching: targetMaskedSiteID,
                    results: &results
                )
            }
        default:
            break
        }
    }

    // MARK: - Pivot

    /// Builds candidates that swap the `.selected` marker to an alternative branch at each pick site.
    private static func pivotCandidates(
        tree: ChoiceTree,
        sequence: ChoiceSequence
    ) -> [ChoiceSequence] {
        let pickSites = extractPickSites(from: tree)
        guard pickSites.isEmpty == false else { return [] }

        var candidates: [ChoiceSequence] = []
        for site in pickSites {
            guard case let .group(elements, _) = tree[site] else { continue }
            guard let selectedIndex = elements.firstIndex(where: \.isSelected) else { continue }

            var alternatives = [(index: Int, complexity: ChoiceSequence)]()
            alternatives.reserveCapacity(elements.count)
            for index in 0 ..< elements.count where index != selectedIndex {
                let complexity = ChoiceSequence.flatten(
                    elements[index],
                    includingAllBranches: true
                )
                alternatives.append((index: index, complexity: complexity))
            }
            alternatives.sort { lhs, rhs in lhs.complexity.shortLexPrecedes(rhs.complexity) }

            for alternative in alternatives {
                var candidateElements = elements
                candidateElements[selectedIndex] = elements[selectedIndex].unwrapped
                let altNode = elements[alternative.index].unwrapped
                candidateElements[alternative.index] = .selected(altNode)

                var candidateTree = tree
                candidateTree[site] = .group(candidateElements)
                let candidateSequence = ChoiceSequence(candidateTree)

                if sequence.shortLexPrecedes(candidateSequence) == false {
                    candidates.append(candidateSequence)
                }
            }
        }
        return candidates
    }
}

// MARK: - Helpers

private func selectedBranchMaskedSiteID(of group: ChoiceTree) -> UInt64? {
    guard case let .group(array, _) = group else { return nil }
    guard let selected = array.first(where: \.isSelected) else { return nil }
    return selected.unwrapped.depthMaskedSiteID
}

private func extractPickSites(from tree: ChoiceTree) -> [Fingerprint] {
    var results: [Fingerprint] = []
    for element in tree.walk() {
        if case let .group(array, _) = element.node,
           array.contains(where: \.unwrapped.isBranch),
           array.contains(where: \.isSelected),
           array.count >= 2
        {
            results.append(element.fingerprint)
        }
    }
    return results
}
