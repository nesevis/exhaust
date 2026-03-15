/// Promotes each branch to a simpler (lower-index) alternative.
///
/// Iterates branch targets from most complex to least complex, trying each simpler branch as a
/// replacement (simplest first). Produces candidate sequences with the branch subtree replaced.
///
/// Set ``currentTree`` before calling ``encode(sequence:targets:)``.
public struct PromoteBranchesEncoder: BatchEncoder {
    public let name = "promoteBranches"

    public var phase: ReductionPhase { .structuralDeletion }

    public var grade: ReductionGrade {
        ReductionGrade(approximation: .exact, maxMaterializations: 0)
    }

    /// The tree to search for branch promotion candidates. Set by the scheduler before each pass.
    var currentTree: ChoiceTree?

    public func encode(
        sequence: ChoiceSequence,
        targets: TargetSet
    ) -> any Sequence<ChoiceSequence> {
        guard let tree = currentTree else { return AnySequence([]) }
        guard tree.contains(\.unwrapped.isBranch) else { return AnySequence([]) }
        let branches = extractBranchNodes(from: tree)
        guard branches.count >= 2 else { return AnySequence([]) }

        let sorted = branches
            .map { branch in (branch: branch, sequence: ChoiceSequence.flatten(branch.node, includingAllBranches: true)) }
            .sorted { lhs, rhs in lhs.sequence.shortLexPrecedes(rhs.sequence) }

        var candidates: [ChoiceSequence] = []
        // while-loop: avoiding IteratorProtocol overhead in debug builds
        var targetIdx = sorted.count - 1
        while targetIdx >= 1 {
            let target = sorted[targetIdx]
            var sourceIdx = 0
            while sourceIdx < targetIdx {
                let source = sorted[sourceIdx]
                if selectedBranchID(of: source.branch.node) != selectedBranchID(of: target.branch.node) {
                    var candidateTree = tree
                    let sourceNode = source.branch.node.unwrapped
                    candidateTree[target.branch.fingerprint] = sourceNode
                    let candidateSequence = ChoiceSequence.flatten(candidateTree)
                    if candidateSequence.shortLexPrecedes(sequence) {
                        candidates.append(candidateSequence)
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

private func selectedBranchID(of group: ChoiceTree) -> UInt64? {
    guard case let .group(array, _) = group else { return nil }
    for element in array {
        if case let .selected(.branch(_, _, id, _, _)) = element {
            return id
        }
    }
    return nil
}
