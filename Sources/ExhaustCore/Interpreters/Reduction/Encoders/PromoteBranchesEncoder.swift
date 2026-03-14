/// Promotes each branch to a simpler (lower-index) alternative.
///
/// Iterates branch targets from most complex to least complex, trying each simpler branch as a replacement (simplest first). Produces candidate sequences with the branch subtree replaced.
public struct PromoteBranchesEncoder: BranchEncoder {
    public let name = "promoteBranches"

    public var grade: ReductionGrade {
        ReductionGrade(approximation: .exact, maxMaterializations: 0)
    }

    public func encode(
        sequence: ChoiceSequence,
        tree: ChoiceTree
    ) -> any Sequence<(ChoiceSequence, ChoiceTree)> {
        guard tree.contains(\.unwrapped.isBranch) else { return AnySequence([]) }
        let branches = extractBranchNodes(from: tree)
        guard branches.count >= 2 else { return AnySequence([]) }

        let sorted = branches
            .map { branch in (branch: branch, sequence: ChoiceSequence.flatten(branch.node, includingAllBranches: true)) }
            .sorted { lhs, rhs in lhs.sequence.shortLexPrecedes(rhs.sequence) }

        var candidates: [(ChoiceSequence, ChoiceTree)] = []
        // while-loop: avoiding IteratorProtocol overhead in debug builds
        var targetIdx = sorted.count - 1
        while targetIdx >= 1 {
            let target = sorted[targetIdx]
            var sourceIdx = 0
            while sourceIdx < targetIdx {
                let source = sorted[sourceIdx]
                if selectedBranchID(of: source.branch.node) != selectedBranchID(of: target.branch.node) {
                    var candidateTree = tree
                    // Strip isRangeExplicit from the promoted subtree. The source
                    // carries stale bind-dependent ranges from its original (deeper)
                    // position; marking them non-explicit lets encoders target zero
                    // instead of the stale range minimum.
                    let sourceNode = source.branch.node.unwrapped
                    let stripped = stripExplicitRanges(sourceNode)
                    candidateTree[target.branch.fingerprint] = stripped
                    let candidateSequence = ChoiceSequence.flatten(candidateTree)
                    if candidateSequence.shortLexPrecedes(sequence) {
                        candidates.append((candidateSequence, candidateTree))
                    }
                }
                sourceIdx += 1
            }
            targetIdx -= 1
        }
        return AnySequence(candidates)
    }
}

// MARK: - Helpers

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

/// Recursively sets `isRangeExplicit = false` on all `.choice` nodes in the
/// subtree. This marks promoted ranges as non-authoritative, letting encoders
/// target zero instead of the (potentially stale) range minimum.
private func stripExplicitRanges(_ tree: ChoiceTree) -> ChoiceTree {
    switch tree {
    case let .choice(value, meta):
        return .choice(value, ChoiceMetadata(validRange: meta.validRange, isRangeExplicit: false))
    case let .selected(inner):
        return .selected(stripExplicitRanges(inner))
    case let .group(children, isOpaque):
        return .group(children.map(stripExplicitRanges), isOpaque: isOpaque)
    case let .branch(siteID, weight, id, branchIDs, choice):
        return .branch(siteID: siteID, weight: weight, id: id,
                        branchIDs: branchIDs, choice: stripExplicitRanges(choice))
    case let .sequence(length, elements, meta):
        return .sequence(length: length, elements: elements.map(stripExplicitRanges), meta)
    case let .bind(inner, bound):
        return .bind(inner: stripExplicitRanges(inner), bound: stripExplicitRanges(bound))
    case let .resize(size, choices):
        return .resize(newSize: size, choices: choices.map(stripExplicitRanges))
    case .just, .getSize:
        return tree
    }
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
