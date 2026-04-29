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
            .selected(.branch(fingerprint: 0, weight: 1, id: 22, branchIDs: UInt64(11) ... UInt64(33), choice: nested)),
            .branch(fingerprint: 0, weight: 1, id: 11, branchIDs: UInt64(11) ... UInt64(33), choice: .just),
            .branch(fingerprint: 0, weight: 1, id: 33, branchIDs: UInt64(11) ... UInt64(33), choice: .just),
        ])
    }

    private func makeRecursiveLikeTree() -> ChoiceTree {
        let meta = ChoiceMetadata(validRange: 0 ... 10)
        let a = ChoiceTree.choice(ChoiceValue(3 as UInt64, tag: .uint64), meta)
        let b = ChoiceTree.choice(ChoiceValue(4 as UInt64, tag: .uint64), meta)
        let c = ChoiceTree.choice(ChoiceValue(5 as UInt64, tag: .uint64), meta)

        let deepestLeafGroup = ChoiceTree.group([a, b, c])
        let deepSelected = ChoiceTree.selected(.branch(
            fingerprint: 0,
            weight: 1,
            id: 302,
            branchIDs: UInt64(301) ... UInt64(302),
            choice: .group([ChoiceTree.just, deepestLeafGroup])
        ))
        let deepOther = ChoiceTree.branch(fingerprint: 0, weight: 1, id: 301, branchIDs: UInt64(301) ... UInt64(302), choice: .just)

        let midSelected = ChoiceTree.selected(.branch(
            fingerprint: 0,
            weight: 1,
            id: 202,
            branchIDs: UInt64(201) ... UInt64(202),
            choice: .group([deepSelected, deepOther])
        ))
        let midOther = ChoiceTree.branch(fingerprint: 0, weight: 1, id: 201, branchIDs: UInt64(201) ... UInt64(202), choice: .just)

        let rootSelected = ChoiceTree.selected(.branch(
            fingerprint: 0,
            weight: 1,
            id: 102,
            branchIDs: UInt64(101) ... UInt64(103),
            choice: .group([midSelected, midOther, ChoiceTree.just])
        ))
        let rootLeft = ChoiceTree.branch(fingerprint: 0, weight: 1, id: 101, branchIDs: UInt64(101) ... UInt64(103), choice: .just)
        let rootRight = ChoiceTree.branch(fingerprint: 0, weight: 1, id: 103, branchIDs: UInt64(101) ... UInt64(103), choice: .just)

        return .group([rootSelected, rootLeft, rootRight])
    }
}
