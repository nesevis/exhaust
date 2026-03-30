//
//  BranchSimplificationEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 23/3/2026.
//

/// Simplifies branches in the choice tree by trying alternative selections.
///
/// Three strategies:
/// - ``Strategy/promoteDirectDescendant``: replaces a branch with a direct descendant branch of the same generator (parent-child collapse). O(N) per pass.
/// - ``Strategy/promote``: replaces complex branches with simpler ones from any other branch site (cross-group substitution). O(N²) per pass.
/// - ``Strategy/pivot``: moves the `.selected` marker to a non-selected alternative within the same branch group.
///
/// The `promoteDirectDescendant` strategy handles the common case of collapsing recursive
/// depth one level at a time (for example, `Div(And(x,y), z)` → `And(x,y)`). It dominates
/// `promote` — when direct descendant promotion makes progress, the expensive exhaustive
/// search is skipped.
///
/// Pre-computes all candidates in ``start()`` and yields them via ``nextProbe()``.
struct BranchSimplificationEncoder: ComposableEncoder {
    enum Strategy {
        case promoteDirectDescendant
        case promote
        case pivot
    }

    let strategy: Strategy

    var name: EncoderName {
        switch strategy {
        case .promoteDirectDescendant: .promoteDirectDescendantBranch
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
        case .promoteDirectDescendant: 5
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
        case .promoteDirectDescendant:
            candidates = Self.directDescendantPromotionCandidates(tree: tree, sequence: sequence)
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

    // MARK: - Direct Descendant Promotion

    /// Builds candidates that replace a branch group with one of its direct descendant
    /// branch groups from the same generator.
    ///
    /// For each branch group in the tree, walks the selected branch's subtree to find
    /// child branch groups with the same `depthMaskedSiteID`. Each such child is a
    /// candidate to replace the parent, collapsing one level of recursive depth.
    /// For example, `Div(And(x,y), Add(a,b))` yields two candidates: `And(x,y)` and `Add(a,b)`.
    ///
    /// Candidates are sorted shortlex-smallest-first so the simplest collapse is tried first.
    private static func directDescendantPromotionCandidates(
        tree: ChoiceTree,
        sequence: ChoiceSequence
    ) -> [ChoiceSequence] {
        guard tree.contains(\.unwrapped.isBranch) else { return [] }

        var candidates: [ChoiceSequence] = []

        for element in tree.walk() {
            guard case let .group(array, _) = element.node,
                  array.contains(where: \.unwrapped.isBranch)
            else { continue }

            let parentMasked = selectedBranchMaskedSiteID(of: element.node)
            guard let parentMasked else { continue }

            // Find the selected branch's subtree and collect direct descendant
            // branch groups with the same depthMaskedSiteID.
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

        // Sort shortlex-smallest-first so the simplest collapses are tried first.
        candidates.sort { $0.shortLexPrecedes($1) }
        return candidates
    }

    /// Finds direct descendant branch groups within a subtree that share the given
    /// `depthMaskedSiteID`.
    ///
    /// "Direct descendant" means the first branch groups encountered when walking
    /// down from the root — once a matching branch group is found, its children
    /// are not searched (they would be grandchildren, not direct descendants).
    private static func directDescendantBranchGroups(
        in subtree: ChoiceTree,
        matching targetMaskedSiteID: UInt64
    ) -> [ChoiceTree] {
        var results: [ChoiceTree] = []
        collectDirectDescendantBranchGroups(
            in: subtree,
            matching: targetMaskedSiteID,
            results: &results
        )
        return results
    }

    private static func collectDirectDescendantBranchGroups(
        in node: ChoiceTree,
        matching targetMaskedSiteID: UInt64,
        results: inout [ChoiceTree]
    ) {
        switch node {
        case let .group(children, _):
            // Check if this group IS a matching branch group.
            if children.contains(where: \.unwrapped.isBranch) {
                if let maskedID = selectedBranchMaskedSiteID(of: node),
                   maskedID == targetMaskedSiteID
                {
                    results.append(node)
                    return // Don't recurse into this group's children.
                }
            }
            // Not a matching branch group — recurse into children.
            for child in children {
                collectDirectDescendantBranchGroups(
                    in: child.unwrapped,
                    matching: targetMaskedSiteID,
                    results: &results
                )
            }
        case let .selected(inner):
            collectDirectDescendantBranchGroups(
                in: inner,
                matching: targetMaskedSiteID,
                results: &results
            )
        case let .bind(_, bound):
            collectDirectDescendantBranchGroups(
                in: bound,
                matching: targetMaskedSiteID,
                results: &results
            )
        case let .branch(_, _, _, _, choice):
            collectDirectDescendantBranchGroups(
                in: choice,
                matching: targetMaskedSiteID,
                results: &results
            )
        case let .sequence(_, elements, _):
            for element in elements {
                collectDirectDescendantBranchGroups(
                    in: element,
                    matching: targetMaskedSiteID,
                    results: &results
                )
            }
        case let .resize(_, choices):
            for choice in choices {
                collectDirectDescendantBranchGroups(
                    in: choice,
                    matching: targetMaskedSiteID,
                    results: &results
                )
            }
        default:
            break
        }
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
           array.contains(where: \.unwrapped.isBranch)
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
           array.contains(where: \.unwrapped.isBranch),
           array.contains(where: \.isSelected),
           array.count >= 2
        {
            results.append(element.fingerprint)
        }
    }
    return results
}
