//
//  ChoiceTreeTests.swift
//  Exhaust
//

import ExhaustCore
import Testing

@Suite("ChoiceTree")
struct ChoiceTreeTests {
    // MARK: - Type predicates

    @Suite("Type predicates")
    struct TypePredicates {
        @Test("isChoice returns true only for .choice")
        func isChoice() {
            #expect(choiceNode.isChoice)
            #expect(!branchNode.isChoice)
            #expect(!justNode.isChoice)
            #expect(!groupNode.isChoice)
            #expect(!getSizeNode.isChoice)
        }

        @Test("isBranch returns true only for .branch")
        func isBranch() {
            #expect(branchNode.isBranch)
            #expect(!choiceNode.isBranch)
            #expect(!justNode.isBranch)
            #expect(!groupNode.isBranch)
        }

        @Test("isJust returns true only for .just")
        func isJust() {
            #expect(justNode.isJust)
            #expect(!choiceNode.isJust)
            #expect(!branchNode.isJust)
            #expect(!groupNode.isJust)
        }

        @Test("isSelected returns true only for .selected")
        func isSelected() {
            let selected = ChoiceTree.selected(justNode)
            #expect(selected.isSelected)
            #expect(!justNode.isSelected)
            #expect(!choiceNode.isSelected)
        }
    }

    // MARK: - containsPicks

    @Suite("containsPicks")
    struct ContainsPicks {
        @Test("Leaf nodes without branches return false")
        func leafsReturnFalse() {
            #expect(!ChoiceTree.just("x").containsPicks)
            #expect(!ChoiceTree.getSize(10).containsPicks)

            let choice = ChoiceTree.choice(
                ChoiceValue(UInt64(1), tag: .uint64),
                ChoiceMetadata(validRange: 0 ... 10),
            )
            #expect(!choice.containsPicks)
        }

        @Test("Branch node returns true")
        func branchReturnsTrue() {
            let branch = ChoiceTree.branch(
                siteID: 0, weight: 1, id: 0, branchIDs: [0, 1],
                choice: .just(""),
            )
            #expect(branch.containsPicks)
        }

        @Test("Nested branch in group is found")
        func nestedBranchInGroup() {
            let branch = ChoiceTree.branch(
                siteID: 0, weight: 1, id: 0, branchIDs: [0],
                choice: .just(""),
            )
            let group = ChoiceTree.group([.just("a"), branch])
            #expect(group.containsPicks)
        }

        @Test("Selected wrapping branch is found")
        func selectedBranch() {
            let branch = ChoiceTree.branch(
                siteID: 0, weight: 1, id: 0, branchIDs: [0],
                choice: .just(""),
            )
            #expect(ChoiceTree.selected(branch).containsPicks)
        }

        @Test("Sequence without picks returns false")
        func sequenceWithoutPicks() {
            let seq = ChoiceTree.sequence(
                length: 2,
                elements: [.just("a"), .just("b")],
                ChoiceMetadata(validRange: 0 ... 10),
            )
            #expect(!seq.containsPicks)
        }

        @Test("Resize containing branch returns true")
        func resizeWithBranch() {
            let branch = ChoiceTree.branch(
                siteID: 0, weight: 1, id: 0, branchIDs: [0],
                choice: .just(""),
            )
            let resize = ChoiceTree.resize(newSize: 50, choices: [branch])
            #expect(resize.containsPicks)
        }
    }

    // MARK: - pickComplexity

    @Suite("pickComplexity")
    struct PickComplexityTests {
        @Test("Leaf nodes have zero complexity")
        func leafZero() {
            #expect(ChoiceTree.just("x").pickComplexity == 0)
            #expect(ChoiceTree.getSize(10).pickComplexity == 0)
        }

        @Test("Single branch complexity equals branch count")
        func singleBranch() {
            let branch = ChoiceTree.branch(
                siteID: 0, weight: 1, id: 0, branchIDs: [0, 1, 2],
                choice: .just(""),
            )
            // 3 branches * 2^0 = 3
            #expect(branch.pickComplexity == 3)
        }

        @Test("Nested branches multiply by depth")
        func nestedBranches() {
            let inner = ChoiceTree.branch(
                siteID: 1, weight: 1, id: 0, branchIDs: [0, 1],
                choice: .just(""),
            )
            let outer = ChoiceTree.branch(
                siteID: 0, weight: 1, id: 0, branchIDs: [0, 1],
                choice: inner,
            )
            // outer: 2 * 2^0 = 2, inner: 2 * 2^1 = 4, max = 4
            #expect(outer.pickComplexity == 4)
        }
    }

    // MARK: - contains(where:)

    @Suite("contains(where:)")
    struct ContainsWhere {
        @Test("Matching predicate on self returns true")
        func matchingSelf() {
            let tree = ChoiceTree.just("target")
            #expect(tree.contains { $0 == .just("target") })
        }

        @Test("Non-matching predicate returns false")
        func nonMatching() {
            let tree = ChoiceTree.just("a")
            #expect(!tree.contains { $0 == .just("b") })
        }

        @Test("Finds nested node in group")
        func findsNested() {
            let target = ChoiceTree.getSize(42)
            let tree = ChoiceTree.group([.just("a"), target])
            #expect(tree.contains { $0 == target })
        }

        @Test("Searches through sequence elements")
        func searchesSequence() {
            let target = ChoiceTree.just("found")
            let seq = ChoiceTree.sequence(
                length: 1,
                elements: [target],
                ChoiceMetadata(validRange: 0 ... 5),
            )
            #expect(seq.contains { $0 == target })
        }

        @Test("Searches through resize children")
        func searchesResize() {
            let target = ChoiceTree.just("found")
            let resize = ChoiceTree.resize(newSize: 10, choices: [target])
            #expect(resize.contains { $0 == target })
        }
    }

    // MARK: - map

    @Suite("map")
    struct MapTests {
        @Test("Transforms leaf node")
        func transformsLeaf() {
            let tree = ChoiceTree.just("old")
            let result = tree.map { node in
                if case .just = node { return .just("new") }
                return node
            }
            #expect(result == .just("new"))
        }

        @Test("Recursively transforms group children")
        func transformsGroupChildren() {
            let tree = ChoiceTree.group([.just("a"), .just("b")])
            let result = tree.map { node in
                if case let .just(s) = node { return .just(s.uppercased()) }
                return node
            }
            #expect(result == .group([.just("A"), .just("B")]))
        }

        @Test("Recursively transforms sequence elements")
        func transformsSequence() {
            let meta = ChoiceMetadata(validRange: 0 ... 5)
            let tree = ChoiceTree.sequence(length: 1, elements: [.just("x")], meta)
            let result = tree.map { node in
                if case let .just(s) = node { return .just(s + "!") }
                return node
            }
            if case let .sequence(_, elements, _) = result {
                #expect(elements == [.just("x!")])
            } else {
                Issue.record("Expected sequence")
            }
        }

        @Test("Transforms through selected wrapper")
        func transformsSelected() {
            let tree = ChoiceTree.selected(.just("inner"))
            let result = tree.map { node in
                if case let .just(s) = node { return .just(s.uppercased()) }
                return node
            }
            #expect(result == .selected(.just("INNER")))
        }

        @Test("Transforms through resize")
        func transformsResize() {
            let tree = ChoiceTree.resize(newSize: 50, choices: [.just("a")])
            let result = tree.map { node in
                if case let .just(s) = node { return .just(s + "!") }
                return node
            }
            if case let .resize(size, choices) = result {
                #expect(size == 50)
                #expect(choices == [.just("a!")])
            } else {
                Issue.record("Expected resize")
            }
        }
    }

    // MARK: - relaxingNonExplicitSequenceLengthRanges

    @Suite("relaxingNonExplicitSequenceLengthRanges")
    struct RelaxRanges {
        @Test("Non-explicit range is widened to full range")
        func nonExplicitWidened() {
            let meta = ChoiceMetadata(validRange: 2 ... 5, isRangeExplicit: false)
            let tree = ChoiceTree.sequence(length: 3, elements: [.just("a")], meta)
            let result = tree.relaxingNonExplicitSequenceLengthRanges()

            if case let .sequence(_, _, newMeta) = result {
                #expect(newMeta.validRange == 0 ... UInt64.max)
                #expect(newMeta.isRangeExplicit == false)
            } else {
                Issue.record("Expected sequence")
            }
        }

        @Test("Explicit range is preserved")
        func explicitPreserved() {
            let meta = ChoiceMetadata(validRange: 2 ... 5, isRangeExplicit: true)
            let tree = ChoiceTree.sequence(length: 3, elements: [.just("a")], meta)
            let result = tree.relaxingNonExplicitSequenceLengthRanges()

            if case let .sequence(_, _, newMeta) = result {
                #expect(newMeta.validRange == 2 ... 5)
                #expect(newMeta.isRangeExplicit == true)
            } else {
                Issue.record("Expected sequence")
            }
        }

        @Test("Non-sequence nodes pass through unchanged")
        func nonSequenceUnchanged() {
            let tree = ChoiceTree.just("hello")
            let result = tree.relaxingNonExplicitSequenceLengthRanges()
            #expect(result == tree)
        }
    }

    // MARK: - unwrapped

    @Suite("unwrapped")
    struct Unwrapped {
        @Test("Selected is unwrapped")
        func selectedUnwrapped() {
            let inner = ChoiceTree.just("inner")
            let tree = ChoiceTree.selected(inner)
            #expect(tree.unwrapped == inner)
        }

        @Test("Nested selected is fully unwrapped")
        func nestedSelectedUnwrapped() {
            let inner = ChoiceTree.just("deep")
            let tree = ChoiceTree.selected(.selected(inner))
            #expect(tree.unwrapped == inner)
        }

        @Test("Non-selected returns self")
        func nonSelectedReturnsSelf() {
            let tree = ChoiceTree.just("hello")
            #expect(tree.unwrapped == tree)
        }
    }

    // MARK: - branchId

    @Suite("branchId")
    struct BranchIdTests {
        @Test("Extracts id from branch")
        func extractsFromBranch() {
            let tree = ChoiceTree.branch(
                siteID: 0, weight: 1, id: 42, branchIDs: [42],
                choice: .just(""),
            )
            #expect(tree.branchId == 42)
        }

        @Test("Extracts id from selected branch")
        func extractsFromSelectedBranch() {
            let branch = ChoiceTree.branch(
                siteID: 0, weight: 1, id: 7, branchIDs: [7],
                choice: .just(""),
            )
            #expect(ChoiceTree.selected(branch).branchId == 7)
        }

        @Test("Returns nil for non-branch")
        func nilForNonBranch() {
            #expect(ChoiceTree.just("x").branchId == nil)
            #expect(ChoiceTree.getSize(5).branchId == nil)
        }
    }
}

// MARK: - Shared fixtures

private let choiceNode = ChoiceTree.choice(
    ChoiceValue(UInt64(5), tag: .uint64),
    ChoiceMetadata(validRange: 0 ... 10),
)
private let branchNode = ChoiceTree.branch(
    siteID: 0, weight: 1, id: 1, branchIDs: [1, 2],
    choice: .just("inner"),
)
private let justNode = ChoiceTree.just("hello")
private let groupNode = ChoiceTree.group([justNode])
private let getSizeNode = ChoiceTree.getSize(50)
