//
//  BranchSimplificationEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 23/3/2026.
//

/// Simplifies branches in the choice tree by trying alternative selections.
///
/// Two strategies:
/// - ``Strategy/promote``: replaces complex branches with simpler ones from other branch sites (cross-group substitution).
/// - ``Strategy/pivot``: moves the `.selected` marker to a non-selected alternative within the same branch group.
///
/// Pre-computes all candidates in ``start()`` and yields them via ``nextProbe()``.
struct BranchSimplificationEncoder: ComposableEncoder {
    enum Strategy {
        case promote
        case pivot
    }

    let strategy: Strategy

    var name: EncoderName {
        switch strategy {
        case .promote: .deleteByPromotingSimplestBranch
        case .pivot: .deleteByPivotingToAlternativeBranch
        }
    }

    let phase = ReductionPhase.structuralDeletion

    init(strategy: Strategy) {
        self.strategy = strategy
    }

    // MARK: - State

    private var candidates: [ChoiceSequence] = []
    private var candidateIndex = 0

    // MARK: - ComposableEncoder

    func estimatedCost(
        sequence: ChoiceSequence,
        tree _: ChoiceTree,
        positionRange _: ClosedRange<Int>,
        context _: ReductionContext
    ) -> Int? {
        guard sequence.isEmpty == false else { return nil }
        return switch strategy {
        case .promote: 20
        case .pivot: 10
        }
    }

    mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange _: ClosedRange<Int>,
        context _: ReductionContext
    ) {
        candidateIndex = 0
        switch strategy {
        case .promote:
            candidates = Self.promotionCandidates(tree: tree, sequence: sequence)
        case .pivot:
            candidates = Self.pivotCandidates(tree: tree, sequence: sequence)
        }
    }

    mutating func nextProbe(lastAccepted _: Bool) -> ChoiceSequence? {
        guard candidateIndex < candidates.count else { return nil }
        let candidate = candidates[candidateIndex]
        candidateIndex += 1
        return candidate
    }

    // MARK: - Promotion

    private static func promotionCandidates(
        tree: ChoiceTree,
        sequence: ChoiceSequence
    ) -> [ChoiceSequence] {
        guard tree.contains(\.unwrapped.isBranch) else { return [] }
        let branches = extractBranchNodes(from: tree)
        guard branches.count >= 2 else { return [] }

        var candidates: [ChoiceSequence] = []
        var targetIdx = 0
        while targetIdx < branches.count {
            let target = branches[targetIdx]
            let targetMasked = selectedBranchMaskedSiteID(of: target.node)
            var sourceIdx = 0
            while sourceIdx < branches.count {
                if sourceIdx != targetIdx {
                    let source = branches[sourceIdx]
                    // Only promote between sites from the same recursive generator
                    // (matching depthMaskedSiteID). Skip if either lacks a site ID.
                    guard let sourceMasked = selectedBranchMaskedSiteID(of: source.node),
                          let targetMasked,
                          sourceMasked == targetMasked
                    else {
                        sourceIdx += 1
                        continue
                    }
                    let sourceID = selectedBranchID(of: source.node)
                    let targetID = selectedBranchID(of: target.node)
                    if sourceID != targetID {
                        var candidateTree = tree
                        let sourceNode = source.node.unwrapped
                        candidateTree[target.fingerprint] = sourceNode
                        let candidateSequence = ChoiceSequence.flatten(candidateTree)
                        // Allow shortlex-equal candidates. With branch-transparent
                        // shortlex, promoting between same-arity sites produces equal
                        // sequences — the property check determines usefulness.
                        if sequence.shortLexPrecedes(candidateSequence) == false {
                            candidates.append(candidateSequence)
                        }
                    }
                }
                sourceIdx += 1
            }
            targetIdx += 1
        }
        return candidates
    }

    // MARK: - Pivot

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

                // Accept candidates that are shortlex-equal (not just strictly better).
                // With branch-transparent shortlex, pivoting between same-arity branches
                // (for example, add ↔ div) produces equal sequences. Allowing these through
                // lets the decoder evaluate the semantic difference — the property check
                // determines whether the alternative branch is useful.
                if sequence.shortLexPrecedes(candidateSequence) == false {
                    candidates.append(candidateSequence)
                }
            }
        }
        return candidates
    }
}

// MARK: - Shared Helpers

private func extractBranchNodes(
    from tree: ChoiceTree
) -> [(fingerprint: Fingerprint, node: ChoiceTree)] {
    var results: [(fingerprint: Fingerprint, node: ChoiceTree)] = []
    for element in tree.walk() {
        if case let .group(array, _) = element.node,
           array.allSatisfy(\.unwrapped.isBranch)
        {
            results.append((element.fingerprint, element.node))
        }
    }
    return results
}

private func selectedBranchMaskedSiteID(of group: ChoiceTree) -> UInt64? {
    guard case let .group(array, _) = group else { return nil }
    guard let selected = array.first(where: \.isSelected) else { return nil }
    return selected.unwrapped.depthMaskedSiteID
}

private func selectedBranchID(of group: ChoiceTree) -> UInt64? {
    guard case let .group(array, _) = group else { return nil }
    for element in array {
        if case let .selected(.branch(_, _, id, _, _)) = element {
            return id
        }
    }
    return nil
}

private func extractPickSites(from tree: ChoiceTree) -> [Fingerprint] {
    var results: [Fingerprint] = []
    for element in tree.walk() {
        if case let .group(array, _) = element.node,
           array.allSatisfy(\.unwrapped.isBranch),
           array.contains(where: \.isSelected),
           array.count >= 2
        {
            results.append(element.fingerprint)
        }
    }
    return results
}
