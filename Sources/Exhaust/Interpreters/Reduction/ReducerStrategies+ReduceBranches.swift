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
        let branches = extractBranchNodes(from: tree)
        guard branches.count >= 2 else {
            return nil
        }

        // Sort branches by shortlex complexity of their flattened sequences (simplest first)
        let sorted = branches
            .map { branch in (branch: branch, sequence: ChoiceSequence.flatten(branch.tree)) }
            .sorted { lhs, rhs in lhs.sequence.shortLexPrecedes(rhs.sequence) }

        // Try replacing complex branches with simpler ones.
        // Iterate targets from most complex to least complex.
        for targetIdx in stride(from: sorted.count - 1, through: 1, by: -1) {
            let target = sorted[targetIdx]

            // Try each simpler branch as a replacement (simplest first)
            for sourceIdx in 0 ..< targetIdx {
                let source = sorted[sourceIdx]
                let candidateTree = replaceBranch(
                    id: target.branch.id,
                    in: tree,
                    with: source.branch.tree,
                )
                let candidateSequence = ChoiceSequence.flatten(candidateTree)

                guard candidateSequence.shortLexPrecedes(sequence) else {
                    continue
                }
                guard rejectCache.contains(candidateSequence) == false else {
                    continue
                }

                guard let output = try? Interpreters.materialize(
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

    /// Extracts all branch nodes from the tree as `(id, branchNode)` tuples.
    private static func extractBranchNodes(
        from tree: ChoiceTree,
    ) -> [(id: UInt64, tree: ChoiceTree)] {
        var results: [(id: UInt64, tree: ChoiceTree)] = []
        _ = tree.map { subTree in
            if case let .branch(_, id, _, _) = subTree {
                results.append((id, subTree))
            }
            return subTree
        }
        return results
    }

    /// Replaces a branch node (identified by `id`) in its parent group with `replacement`.
    /// Preserves the `selected` wrapper when the target branch was selected.
    private static func replaceBranch(
        id: UInt64,
        in tree: ChoiceTree,
        with replacement: ChoiceTree,
    ) -> ChoiceTree {
        tree.map { subTree in
            if case let .group(children) = subTree,
               children.contains(where: { $0.branchId == id })
            {
                let replaced = children.map { child in
                    child.branchId == id
                        ? (child.isSelected ? .selected(replacement.unwrapped) : replacement)
                        : child
                }
                return .group(replaced)
            }
            return subTree
        }
    }
}
