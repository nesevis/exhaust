//
//  PickBranchResolution.swift
//  Exhaust
//
//  Created by Codex on 21/2/2026.
//

enum PickBranchResolution {
    struct Branch {
        let id: UInt64
        let choice: ChoiceTree
        let isSelected: Bool
    }

    @inline(__always)
    static func unpack(_ branch: ChoiceTree) -> Branch? {
        switch branch {
        case let .branch(_, id, _, choice):
            return Branch(id: id, choice: choice, isSelected: false)
        case let .selected(.branch(_, id, _, choice)):
            return Branch(id: id, choice: choice, isSelected: true)
        default:
            return nil
        }
    }

    @inline(__always)
    static func generator(
        for id: UInt64,
        in choices: ContiguousArray<ReflectiveOperation.PickTuple>,
    ) -> ReflectiveGenerator<Any>? {
        choices.first(where: { $0.id == id })?.generator
    }

    @inline(__always)
    static func normalizeReplayBranches(_ branches: [ChoiceTree]) -> [ChoiceTree] {
        if branches.contains(where: \.isSelected) {
            return branches.filter(\.isSelected)
        }
        return branches
    }

    @inline(__always)
    static func firstSelectedBranch(in branches: [ChoiceTree]) -> ChoiceTree? {
        branches.first(where: \.isSelected)
    }
}
