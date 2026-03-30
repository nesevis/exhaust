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
        let leaf1 = ChoiceTree.choice(.unsigned(1, .uint64), meta)
        let leaf2 = ChoiceTree.choice(.unsigned(2, .uint64), meta)
        let deepDescendant = ChoiceTree.group([leaf1, leaf2])
        let nested = ChoiceTree.group([ChoiceTree.just, deepDescendant])

        return .group([
            .selected(.branch(siteID: 0, weight: 1, id: 22, branchIDs: [11, 22, 33], choice: nested)),
            .branch(siteID: 0, weight: 1, id: 11, branchIDs: [11, 22, 33], choice: .just),
            .branch(siteID: 0, weight: 1, id: 33, branchIDs: [11, 22, 33], choice: .just),
        ])
    }

    private func makeRecursiveLikeTree() -> ChoiceTree {
        let meta = ChoiceMetadata(validRange: 0 ... 10)
        let a = ChoiceTree.choice(.unsigned(3, .uint64), meta)
        let b = ChoiceTree.choice(.unsigned(4, .uint64), meta)
        let c = ChoiceTree.choice(.unsigned(5, .uint64), meta)

        let deepestLeafGroup = ChoiceTree.group([a, b, c])
        let deepSelected = ChoiceTree.selected(.branch(
            siteID: 0,
            weight: 1,
            id: 302,
            branchIDs: [301, 302],
            choice: .group([ChoiceTree.just, deepestLeafGroup])
        ))
        let deepOther = ChoiceTree.branch(siteID: 0, weight: 1, id: 301, branchIDs: [301, 302], choice: .just)

        let midSelected = ChoiceTree.selected(.branch(
            siteID: 0,
            weight: 1,
            id: 202,
            branchIDs: [201, 202],
            choice: .group([deepSelected, deepOther])
        ))
        let midOther = ChoiceTree.branch(siteID: 0, weight: 1, id: 201, branchIDs: [201, 202], choice: .just)

        let rootSelected = ChoiceTree.selected(.branch(
            siteID: 0,
            weight: 1,
            id: 102,
            branchIDs: [101, 102, 103],
            choice: .group([midSelected, midOther, ChoiceTree.just])
        ))
        let rootLeft = ChoiceTree.branch(siteID: 0, weight: 1, id: 101, branchIDs: [101, 102, 103], choice: .just)
        let rootRight = ChoiceTree.branch(siteID: 0, weight: 1, id: 103, branchIDs: [101, 102, 103], choice: .just)

        return .group([rootSelected, rootLeft, rootRight])
    }
}
