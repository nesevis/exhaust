//
//  DeleteByBranchPivotEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 14/3/2026.
//

/// Pivots each branch by trying alternative (non-selected) branches at each pick site.
///
/// Tries alternatives sorted by shortlex complexity (simplest first). Produces candidate
/// sequences with the `.selected` marker moved to the alternative.
///
/// Set ``currentTree`` before calling ``encode(sequence:targets:)``.
public struct DeleteByBranchPivotEncoder: BatchEncoder {
    public let name: EncoderName = .deleteByPivotingToAlternativeBranch

    public var phase: ReductionPhase {
        .structuralDeletion
    }

    public func estimatedCost(sequence: ChoiceSequence, bindIndex _: BindSpanIndex?) -> Int? {
        guard sequence.isEmpty == false else { return nil }
        // Fixed estimate: enumerates pick sites and tries each non-selected alternative sorted by shortlex complexity, bounded by the number of pick sites in the tree.
        return 10
    }

    /// The tree to search for pivot candidates. Set by the scheduler before each pass.
    var currentTree: ChoiceTree?

    public func encode(
        sequence: ChoiceSequence,
        targets _: TargetSet
    ) -> any Sequence<ChoiceSequence> {
        guard let tree = currentTree else { return AnySequence([]) }
        let pickSites = extractPickSites(from: tree)
        guard pickSites.isEmpty == false else { return AnySequence([]) }

        var candidates: [ChoiceSequence] = []
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
                    candidates.append(candidateSequence)
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
