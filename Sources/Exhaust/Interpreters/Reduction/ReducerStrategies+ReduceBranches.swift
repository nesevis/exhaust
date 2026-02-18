//
//  ReducerStrategies+ReduceBranches.swift
//  Exhaust
//
//  Created by Chris Kolbu on 18/2/2026.
//

extension ReducerStrategies {
    /// Pass: reduce pick-branch structure by replacing a complex branch's
    /// subtree with a simpler sub-branch, ordered by shortlex complexity.
    static func reduceBranches<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        rejectCache: inout ReducerCache,
    ) throws -> (ChoiceTree, ChoiceSequence, Output)? {
        guard tree.contains(\.unwrapped.isBranch) else {
            return nil
        }
        // TODO: Flip selected branch? Does not require jiggery-pokery with gen–choiceTree mismatches
        
        let branches = extractBranchNodes(from: tree)
        guard branches.count >= 2 else {
            return nil
        }

        // Sort branches by shortlex complexity of their flattened sequences (simplest first)
        let sorted = branches
            .map { branch in (branch: branch, sequence: ChoiceSequence.flatten(branch.node)) }
            .sorted { lhs, rhs in lhs.sequence.shortLexPrecedes(rhs.sequence) }

        // Try replacing complex branches with simpler ones.
        // Iterate targets from most complex to least complex.
        for targetIdx in stride(from: sorted.count - 1, through: 1, by: -1) {
            let target = sorted[targetIdx]

            // Try each simpler branch as a replacement (simplest first)
            for sourceIdx in 0 ..< targetIdx {
                let source = sorted[sourceIdx]

                // Skip if source is nested inside target — replacing the parent
                // with a descendant's content changes tree depth and breaks materialization.
                let targetFP = target.branch.fingerprint
                let sourceFP = source.branch.fingerprint

                var candidateTree = tree
                // Use .unwrapped to strip any .selected/.important wrapper from the source;
                // the parent structure at the target fingerprint is preserved by the subscript setter.
                candidateTree[targetFP] = source.branch.node.unwrapped
                let candidateSequence = ChoiceSequence.flatten(candidateTree)

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

    /// Extracts all branch nodes from the tree as `(fingerprint, node)` pairs.
    /// Fingerprints point to the `.branch` node itself (inside any `.selected` wrapper).
    private static func extractBranchNodes(
        from tree: ChoiceTree,
    ) -> [(fingerprint: Fingerprint, node: ChoiceTree)] {
        var results: [(fingerprint: Fingerprint, node: ChoiceTree)] = []
        for element in tree.walk() {
            if
                case let .group(array) = element.node,
                array.allSatisfy({ $0.unwrapped.isBranch })
            {
                results.append((element.fingerprint, element.node))
            }
        }
        return results
    }
}
