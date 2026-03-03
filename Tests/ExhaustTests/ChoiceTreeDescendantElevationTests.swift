//
//  ChoiceTreeDescendantElevationTests.swift
//  ExhaustTests
//

import Testing
@testable import Exhaust
@_spi(ExhaustInternal) import ExhaustCore

@Suite("ChoiceTree descendant elevation")
struct ChoiceTreeDescendantElevationTests {
    private func makeTree() -> ChoiceTree {
        let meta = ChoiceMetadata(validRange: 0 ... 10)
        let leaf1 = ChoiceTree.choice(.unsigned(1, UInt64.self), meta)
        let leaf2 = ChoiceTree.choice(.unsigned(2, UInt64.self), meta)
        let deepDescendant = ChoiceTree.group([leaf1, leaf2])
        let nested = ChoiceTree.group([ChoiceTree.just("x"), deepDescendant])

        return .group([
            .selected(.branch(siteID: 0, weight: 1, id: 22, branchIDs: [11, 22, 33], choice: nested)),
            .branch(siteID: 0, weight: 1, id: 11, branchIDs: [11, 22, 33], choice: .just("left")),
            .branch(siteID: 0, weight: 1, id: 33, branchIDs: [11, 22, 33], choice: .just("right")),
        ])
    }

    private func makeRecursiveLikeTree() -> ChoiceTree {
        let meta = ChoiceMetadata(validRange: 0 ... 10)
        let a = ChoiceTree.choice(.unsigned(3, UInt64.self), meta)
        let b = ChoiceTree.choice(.unsigned(4, UInt64.self), meta)
        let c = ChoiceTree.choice(.unsigned(5, UInt64.self), meta)

        let deepestLeafGroup = ChoiceTree.group([a, b, c])
        let deepSelected = ChoiceTree.selected(.branch(
            siteID: 0,
            weight: 1,
            id: 302,
            branchIDs: [301, 302],
            choice: .group([ChoiceTree.just("node"), deepestLeafGroup]),
        ))
        let deepOther = ChoiceTree.branch(siteID: 0, weight: 1, id: 301, branchIDs: [301, 302], choice: .just("alt"))

        let midSelected = ChoiceTree.selected(.branch(
            siteID: 0,
            weight: 1,
            id: 202,
            branchIDs: [201, 202],
            choice: .group([deepSelected, deepOther]),
        ))
        let midOther = ChoiceTree.branch(siteID: 0, weight: 1, id: 201, branchIDs: [201, 202], choice: .just("mid-alt"))

        let rootSelected = ChoiceTree.selected(.branch(
            siteID: 0,
            weight: 1,
            id: 102,
            branchIDs: [101, 102, 103],
            choice: .group([midSelected, midOther, ChoiceTree.just("tail")]),
        ))
        let rootLeft = ChoiceTree.branch(siteID: 0, weight: 1, id: 101, branchIDs: [101, 102, 103], choice: .just("left"))
        let rootRight = ChoiceTree.branch(siteID: 0, weight: 1, id: 103, branchIDs: [101, 102, 103], choice: .just("right"))

        return .group([rootSelected, rootLeft, rootRight])
    }
}
