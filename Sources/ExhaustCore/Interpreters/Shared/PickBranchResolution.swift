//
//  PickBranchResolution.swift
//  Exhaust
//
//  Created by Codex on 21/2/2026.
//

/// Utilities for extracting and resolving pick-site branches from a ``ChoiceTree``.
package enum PickBranchResolution {
    /// A resolved branch from a pick site, carrying its identifier, subtree, and selection state.
    package struct Branch {
        /// The branch identifier.
        package let id: UInt64
        /// The subtree rooted at this branch.
        package let choice: ChoiceTree
        /// Whether this branch was the one selected during generation.
        package let isSelected: Bool
    }

    /// Extracts a ``Branch`` from a ``ChoiceTree/branch`` node, returning `nil` for other node kinds.
    @inline(__always)
    package static func unpack(_ branch: ChoiceTree) -> Branch? {
        guard case let .branch(_, _, id, _, choice, isSelected) = branch else {
            return nil
        }
        return Branch(id: id, choice: choice, isSelected: isSelected)
    }

    /// Returns the generator for the branch with the given identifier, or `nil` if the identifier is out of range.
    @inline(__always)
    package static func generator(
        for id: UInt64,
        in choices: ContiguousArray<ReflectiveOperation.PickTuple>
    ) -> ReflectiveGenerator<Any>? {
        let index = Int(id)
        guard index < choices.count else { return nil }
        return choices[index].generator
    }

    /// Filters replay branches to only selected branches when any selection markers exist, passing through unchanged otherwise.
    package static func normalizeReplayBranches(_ branches: [ChoiceTree]) -> [ChoiceTree] {
        if branches.contains(where: \.isSelected) {
            return branches.filter(\.isSelected)
        }
        return branches
    }
}
