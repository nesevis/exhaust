//
//  PickBranchResolution.swift
//  Exhaust
//
//  Created by Codex on 21/2/2026.
//

/// Utilities for extracting and resolving pick-site branches from a ``ChoiceTree``.
package enum PickBranchResolution {
    /// A resolved branch from a pick site, carrying its identifier, subtree, and selection state.
    public struct Branch {
        /// The branch identifier.
        public let id: UInt64
        /// The subtree rooted at this branch.
        public let choice: ChoiceTree
        /// Whether this branch was the one selected during generation.
        public let isSelected: Bool
    }

    /// Extracts a ``Branch`` from a ``ChoiceTree/branch`` or ``ChoiceTree/selected`` node, returning `nil` for other node kinds.
    @inline(__always)
    public static func unpack(_ branch: ChoiceTree) -> Branch? {
        switch branch {
        case let .branch(_, _, id, _, choice):
            Branch(id: id, choice: choice, isSelected: false)
        case let .selected(.branch(_, _, id, _, choice)):
            Branch(id: id, choice: choice, isSelected: true)
        default:
            nil
        }
    }

    /// Returns the generator for the branch with the given identifier, or `nil` if no match exists.
    @inline(__always)
    public static func generator(
        for id: UInt64,
        in choices: ContiguousArray<ReflectiveOperation.PickTuple>
    ) -> ReflectiveGenerator<Any>? {
        choices.first(where: { $0.id == id })?.generator
    }

    /// Filters replay branches to only selected branches when any selection markers exist, passing through unchanged otherwise.
    @inline(__always)
    public static func normalizeReplayBranches(_ branches: [ChoiceTree]) -> [ChoiceTree] {
        if branches.contains(where: \.isSelected) {
            return branches.filter(\.isSelected)
        }
        return branches
    }

}
