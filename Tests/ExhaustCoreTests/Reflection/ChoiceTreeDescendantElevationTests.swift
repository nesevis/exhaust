//
//  ChoiceTreeDescendantElevationTests.swift
//  ExhaustTests
//

import ExhaustCore
import Testing

@Suite("ChoiceTree descendant elevation")
struct ChoiceTreeDescendantElevationTests {
    private func makeTree() -> ChoiceTree {
        let meta = ChoiceMetadata(validRange: 0 ... 10)
        let leaf1 = ChoiceTree.choice(ChoiceValue(1 as UInt64, tag: .uint64), meta)
        let leaf2 = ChoiceTree.choice(ChoiceValue(2 as UInt64, tag: .uint64), meta)
        let deepDescendant = ChoiceTree.group([leaf1, leaf2])
        let nested = ChoiceTree.group([ChoiceTree.just, deepDescendant])

        return .group([
            .branch(fingerprint: 0, weight: 1, id: 22, branchCount: 23, choice: nested, isSelected: true),
            .branch(fingerprint: 0, weight: 1, id: 11, branchCount: 23, choice: .just),
            .branch(fingerprint: 0, weight: 1, id: 33, branchCount: 23, choice: .just),
        ])
    }

    private func makeRecursiveLikeTree() -> ChoiceTree {
        let meta = ChoiceMetadata(validRange: 0 ... 10)
        let a = ChoiceTree.choice(ChoiceValue(3 as UInt64, tag: .uint64), meta)
        let b = ChoiceTree.choice(ChoiceValue(4 as UInt64, tag: .uint64), meta)
        let c = ChoiceTree.choice(ChoiceValue(5 as UInt64, tag: .uint64), meta)

        let deepestLeafGroup = ChoiceTree.group([a, b, c])
        let deepSelected = ChoiceTree.branch(
            fingerprint: 0,
            weight: 1,
            id: 302,
            branchCount: 2,
            choice: .group([ChoiceTree.just, deepestLeafGroup]),
            isSelected: true
        )
        let deepOther = ChoiceTree.branch(fingerprint: 0, weight: 1, id: 301, branchCount: 2, choice: .just)

        let midSelected = ChoiceTree.branch(
            fingerprint: 0,
            weight: 1,
            id: 202,
            branchCount: 2,
            choice: .group([deepSelected, deepOther]),
            isSelected: true
        )
        let midOther = ChoiceTree.branch(fingerprint: 0, weight: 1, id: 201, branchCount: 2, choice: .just)

        let rootSelected = ChoiceTree.branch(
            fingerprint: 0,
            weight: 1,
            id: 102,
            branchCount: 3,
            choice: .group([midSelected, midOther, ChoiceTree.just]),
            isSelected: true
        )
        let rootLeft = ChoiceTree.branch(fingerprint: 0, weight: 1, id: 101, branchCount: 3, choice: .just)
        let rootRight = ChoiceTree.branch(fingerprint: 0, weight: 1, id: 103, branchCount: 3, choice: .just)

        return .group([rootSelected, rootLeft, rootRight])
    }
}
