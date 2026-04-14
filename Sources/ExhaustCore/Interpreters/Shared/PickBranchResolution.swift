//
//  PickBranchResolution.swift
//  Exhaust
//
//  Created by Codex on 21/2/2026.
//

package enum PickBranchResolution {
    public struct Branch {
        public let id: UInt64
        public let choice: ChoiceTree
        public let isSelected: Bool
    }

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

    @inline(__always)
    public static func generator(
        for id: UInt64,
        in choices: ContiguousArray<ReflectiveOperation.PickTuple>
    ) -> ReflectiveGenerator<Any>? {
        choices.first(where: { $0.id == id })?.generator
    }

    @inline(__always)
    public static func normalizeReplayBranches(_ branches: [ChoiceTree]) -> [ChoiceTree] {
        if branches.contains(where: \.isSelected) {
            return branches.filter(\.isSelected)
        }
        return branches
    }

}
