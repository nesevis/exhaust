//
//  ReducerStrategies+PivotBranches.swift
//  Exhaust
//
//  Created by Chris Kolbu on 19/2/2026.
//

extension ReducerStrategies {
    /// Pass: try switching which branch is `.selected` at each pick site,
    /// preferring alternatives whose subtrees are shortlex-simpler.
    ///
    /// Requires the tree to have been generated with `materializePicks: true`
    /// so that alternative (non-selected) branches are present in each group.
    static func pivotBranches<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        rejectCache: inout ReducerCache,
    ) throws -> (ChoiceTree, ChoiceSequence, Output)? {
        let pickSites = extractPickSites(from: tree)
        guard !pickSites.isEmpty else { return nil }

        for site in pickSites {
            guard case let .group(elements) = tree[site] else { continue }

            // Find the index of the currently selected branch
            guard let selectedIndex = elements.firstIndex(where: \.isSelected) else { continue }

            // Build alternatives sorted by shortlex complexity (simplest first)
            let alternatives = elements.enumerated()
                .filter { $0.offset != selectedIndex }
                .map { (index: $0.offset, complexity: ChoiceSequence.flatten($0.element, includingAllBranches: true)) }
                .sorted { lhs, rhs in lhs.complexity.shortLexPrecedes(rhs.complexity) }

            guard !alternatives.isEmpty else { continue }

            for alternative in alternatives {
                // Build a candidate group: strip .selected from current, wrap alternative in .selected
                var candidateElements = elements
                candidateElements[selectedIndex] = elements[selectedIndex].unwrapped
                candidateElements[alternative.index] = .selected(elements[alternative.index].unwrapped)

                var candidateTree = tree
                candidateTree[site] = .group(candidateElements)

                let candidateSequence = ChoiceSequence(candidateTree)

                guard candidateSequence.shortLexPrecedes(sequence) else {
                    continue
                }
                guard rejectCache.contains(candidateSequence) == false else {
                    continue
                }

                guard let output = try Interpreters.materialize(
                    gen,
                    with: candidateTree,
                    using: candidateSequence,
                    strictness: .relaxed,
                ) else {
                    rejectCache.insert(candidateSequence)
                    continue
                }
                if property(output) == false {
                    return (candidateTree, candidateSequence, output)
                }
                rejectCache.insert(candidateSequence)
            }
        }

        return nil
    }

    /// Extracts fingerprints of pick-site groups that contain at least one `.selected`
    /// branch and at least one non-selected alternative.
    private static func extractPickSites(from tree: ChoiceTree) -> [Fingerprint] {
        var results: [Fingerprint] = []
        for element in tree.walk() {
            if case let .group(array) = element.node,
               array.allSatisfy(\.unwrapped.isBranch),
               array.contains(where: \.isSelected),
               array.count >= 2
            {
                results.append(element.fingerprint)
            }
        }
        return results
    }
}
