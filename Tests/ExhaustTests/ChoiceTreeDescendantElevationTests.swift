//
//  ChoiceTreeDescendantElevationTests.swift
//  ExhaustTests
//

import Testing
@testable import Exhaust

@Suite("ChoiceTree descendant elevation")
struct ChoiceTreeDescendantElevationTests {
    private func makeTree() -> ChoiceTree {
        let meta = ChoiceMetadata(validRanges: [0 ... 10])
        let leaf1 = ChoiceTree.choice(.unsigned(1, UInt64.self), meta)
        let leaf2 = ChoiceTree.choice(.unsigned(2, UInt64.self), meta)
        let deepDescendant = ChoiceTree.group([leaf1, leaf2])
        let nested = ChoiceTree.group([ChoiceTree.just("x"), deepDescendant])

        return .group([
            .selected(.branch(weight: 1, id: 22, branchIDs: [11, 22, 33], choice: nested)),
            .branch(weight: 1, id: 11, branchIDs: [11, 22, 33], choice: .just("left")),
            .branch(weight: 1, id: 33, branchIDs: [11, 22, 33], choice: .just("right")),
        ])
    }

    private func makeRecursiveLikeTree() -> ChoiceTree {
        let meta = ChoiceMetadata(validRanges: [0 ... 10])
        let a = ChoiceTree.choice(.unsigned(3, UInt64.self), meta)
        let b = ChoiceTree.choice(.unsigned(4, UInt64.self), meta)
        let c = ChoiceTree.choice(.unsigned(5, UInt64.self), meta)

        let deepestLeafGroup = ChoiceTree.group([a, b, c])
        let deepSelected = ChoiceTree.selected(.branch(
            weight: 1,
            id: 302,
            branchIDs: [301, 302],
            choice: .group([ChoiceTree.just("node"), deepestLeafGroup]),
        ))
        let deepOther = ChoiceTree.branch(weight: 1, id: 301, branchIDs: [301, 302], choice: .just("alt"))

        let midSelected = ChoiceTree.selected(.branch(
            weight: 1,
            id: 202,
            branchIDs: [201, 202],
            choice: .group([deepSelected, deepOther]),
        ))
        let midOther = ChoiceTree.branch(weight: 1, id: 201, branchIDs: [201, 202], choice: .just("mid-alt"))

        let rootSelected = ChoiceTree.selected(.branch(
            weight: 1,
            id: 102,
            branchIDs: [101, 102, 103],
            choice: .group([midSelected, midOther, ChoiceTree.just("tail")]),
        ))
        let rootLeft = ChoiceTree.branch(weight: 1, id: 101, branchIDs: [101, 102, 103], choice: .just("left"))
        let rootRight = ChoiceTree.branch(weight: 1, id: 103, branchIDs: [101, 102, 103], choice: .just("right"))

        return .group([rootSelected, rootLeft, rootRight])
    }

    @Test("first finds nested descendant inside selected branch")
    func firstFindsNestedDescendant() throws {
        let tree = makeTree()
        let found = tree.first { node in
            if case let .choice(.unsigned(value, _), _) = node {
                return value == 2
            }
            return false
        }

        let match = try #require(found)
        guard case let .choice(.unsigned(value, _), _) = match else {
            Issue.record("Expected unsigned choice")
            return
        }
        #expect(value == 2)
    }

    @Test("map can replace branch choice with descendant by branch id")
    func mapReplacesChoiceWithDescendant() throws {
        let original = makeTree()

        let branchNode = try #require(original.first { node in
            if case let .selected(.branch(_, id, _, _)) = node {
                return id == 22
            }
            return false
        })
        guard case let .selected(.branch(_, _, _, branchChoice)) = branchNode else {
            Issue.record("Expected selected branch")
            return
        }

        let descendant = try #require(branchChoice.first { node in
            if case let .group(children) = node {
                // pick the inner group [leaf1, leaf2], not the outer wrapper
                return children.allSatisfy { child in
                    if case .choice = child { return true }
                    return false
                }
            }
            return false
        })

        let elevated = original.map { node in
            switch node {
            case let .selected(.branch(weight, id, branchIDs, _)) where id == 22:
                return .selected(.branch(weight: weight, id: id, branchIDs: branchIDs, choice: descendant))
            default:
                return node
            }
        }

        #expect(elevated != original)
        #expect(elevated.structuralComplexity < original.structuralComplexity)
    }

    @Test("descendant elevation shortens flattened sequence")
    func elevationShortensFlattenedSequence() throws {
        let original = makeTree()

        let branchNode = try #require(original.first { node in
            if case let .selected(.branch(_, id, _, _)) = node {
                return id == 22
            }
            return false
        })
        guard case let .selected(.branch(_, _, _, branchChoice)) = branchNode else {
            Issue.record("Expected selected branch")
            return
        }

        let descendant = try #require(branchChoice.first { node in
            if case let .group(children) = node {
                return children.allSatisfy { child in
                    if case .choice = child { return true }
                    return false
                }
            }
            return false
        })

        let elevated = original.map { node in
            switch node {
            case let .selected(.branch(weight, id, branchIDs, _)) where id == 22:
                return .selected(.branch(weight: weight, id: id, branchIDs: branchIDs, choice: descendant))
            default:
                return node
            }
        }

        let originalSequence = ChoiceSequence.flatten(original)
        let elevatedSequence = ChoiceSequence.flatten(elevated)

        #expect(elevatedSequence.shortLexPrecedes(originalSequence))
        #expect(elevatedSequence.count < originalSequence.count)
    }

    @Test("first locates deeply nested recursive selected branch by id")
    func firstFindsDeepRecursiveBranchByID() throws {
        let tree = makeRecursiveLikeTree()
        let deep = try #require(tree.first { node in
            if case let .selected(.branch(_, id, _, _)) = node {
                return id == 302
            }
            return false
        })

        guard case let .selected(.branch(_, id, _, _)) = deep else {
            Issue.record("Expected selected deep branch")
            return
        }
        #expect(id == 302)
    }

    @Test("map elevates recursive branch to collapse nested pick")
    func mapElevatesDeepRecursiveBranch() throws {
        let original = makeRecursiveLikeTree()

        let deepBranch = try #require(original.first { node in
            if case let .selected(.branch(_, id, _, _)) = node {
                return id == 202
            }
            return false
        })
        guard case let .selected(.branch(_, _, _, deepChoice)) = deepBranch else {
            Issue.record("Expected deep selected branch")
            return
        }

        let descendant = try #require(deepChoice.first { node in
            if case let .group(children) = node {
                return children.allSatisfy { child in
                    if case .choice = child { return true }
                    return false
                }
            }
            return false
        })

        let elevated = original.map { node in
            switch node {
            case let .selected(.branch(weight, id, branchIDs, _)) where id == 202:
                return .selected(.branch(weight: weight, id: id, branchIDs: branchIDs, choice: descendant))
            default:
                return node
            }
        }

        let originalSequence = ChoiceSequence.flatten(original)
        let elevatedSequence = ChoiceSequence.flatten(elevated)
        let originalBranchMarkers = originalSequence.count { element in
            if case .branch = element { return true }
            return false
        }
        let elevatedBranchMarkers = elevatedSequence.count { element in
            if case .branch = element { return true }
            return false
        }
        
        print(originalSequence.shortString)
        print(elevatedSequence.shortString)

        #expect(elevated.structuralComplexity < original.structuralComplexity)
        #expect(elevatedSequence.count < originalSequence.count)
        #expect(elevatedSequence.shortLexPrecedes(originalSequence))
        #expect(originalBranchMarkers == 2)
        #expect(elevatedBranchMarkers == 1)
    }
}
