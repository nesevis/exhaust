/// Pivots each branch by trying alternative (non-selected) branches at each pick site.
///
/// Tries alternatives sorted by shortlex complexity (simplest first). Produces candidate sequences with the `.selected` marker moved to the alternative.
public struct PivotBranchesEncoder: BranchEncoder {
    public let name = "pivotBranches"

    public var grade: ReductionGrade {
        ReductionGrade(approximation: .exact, maxMaterializations: 0)
    }

    public func encode(
        sequence: ChoiceSequence,
        tree: ChoiceTree
    ) -> any Sequence<(ChoiceSequence, ChoiceTree)> {
        let pickSites = extractPickSites(from: tree)
        guard pickSites.isEmpty == false else { return AnySequence([]) }

        var candidates: [(ChoiceSequence, ChoiceTree)] = []
        for site in pickSites {
            guard case let .group(elements, _) = tree[site] else { continue }
            guard let selectedIndex = elements.firstIndex(where: \.isSelected) else { continue }

            let alternatives = elements.enumerated()
                .filter { $0.offset != selectedIndex }
                .map { (index: $0.offset, complexity: ChoiceSequence.flatten($0.element, includingAllBranches: true)) }
                .sorted { lhs, rhs in lhs.complexity.shortLexPrecedes(rhs.complexity) }

            for alternative in alternatives {
                var candidateElements = elements
                candidateElements[selectedIndex] = elements[selectedIndex].unwrapped
                candidateElements[alternative.index] = .selected(elements[alternative.index].unwrapped)

                var candidateTree = tree
                candidateTree[site] = .group(candidateElements)
                let candidateSequence = ChoiceSequence(candidateTree)

                if candidateSequence.shortLexPrecedes(sequence) {
                    candidates.append((candidateSequence, candidateTree))
                }
            }
        }
        return AnySequence(candidates)
    }
}

// MARK: - Helpers

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
