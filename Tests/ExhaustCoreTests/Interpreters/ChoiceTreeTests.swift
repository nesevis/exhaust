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

        @Test("isSelected returns true only for branch with isSelected: true")
        func isSelected() {
            let selected = ChoiceTree.branch(
                fingerprint: 0, weight: 1, id: 0, branchCount: 1,
                choice: justNode, isSelected: true
            )
            #expect(selected.isSelected)
            #expect(justNode.isSelected == false)
            #expect(choiceNode.isSelected == false)
        }
    }

    // MARK: - containsPicks

    @Suite("containsPicks")
    struct ContainsPicks {
        @Test("Leaf nodes without branches return false")
        func leafsReturnFalse() {
            #expect(!ChoiceTree.just.containsPicks)
            #expect(!ChoiceTree.getSize(10).containsPicks)

            let choice = ChoiceTree.choice(
                ChoiceValue(UInt64(1), tag: .uint64),
                ChoiceMetadata(validRange: 0 ... 10)
            )
            #expect(!choice.containsPicks)
        }

        @Test("Branch node returns true")
        func branchReturnsTrue() {
            let branch = ChoiceTree.branch(
                fingerprint: 0, weight: 1, id: 0, branchCount: 2,
                choice: .just
            )
            #expect(branch.containsPicks)
        }

        @Test("Nested branch in group is found")
        func nestedBranchInGroup() {
            let branch = ChoiceTree.branch(
                fingerprint: 0, weight: 1, id: 0, branchCount: 1,
                choice: .just
            )
            let group = ChoiceTree.group([.just, branch])
            #expect(group.containsPicks)
        }

        @Test("Selected wrapping branch is found")
        func selectedBranch() {
            let branch = ChoiceTree.branch(
                fingerprint: 0, weight: 1, id: 0, branchCount: 1,
                choice: .just
            )
            #expect(branch.selecting().containsPicks)
        }

        @Test("Sequence without picks returns false")
        func sequenceWithoutPicks() {
            let seq = ChoiceTree.sequence(
                length: 2,
                elements: [.just, .just],
                ChoiceMetadata(validRange: 0 ... 10)
            )
            #expect(!seq.containsPicks)
        }

        @Test("Resize containing branch returns true")
        func resizeWithBranch() {
            let branch = ChoiceTree.branch(
                fingerprint: 0, weight: 1, id: 0, branchCount: 1,
                choice: .just
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
            #expect(ChoiceTree.just.pickComplexity == 0)
            #expect(ChoiceTree.getSize(10).pickComplexity == 0)
        }

        @Test("Single branch complexity equals branch count")
        func singleBranch() {
            let branch = ChoiceTree.branch(
                fingerprint: 0, weight: 1, id: 0, branchCount: 3,
                choice: .just
            )
            // 3 branches * 2^0 = 3
            #expect(branch.pickComplexity == 3)
        }

        @Test("Nested branches multiply by depth")
        func nestedBranches() {
            let inner = ChoiceTree.branch(
                fingerprint: 1, weight: 1, id: 0, branchCount: 2,
                choice: .just
            )
            let outer = ChoiceTree.branch(
                fingerprint: 0, weight: 1, id: 0, branchCount: 2,
                choice: inner
            )
            // outer: 2 * 2^0 = 2, inner: 2 * 2^1 = 4, max = 4
            #expect(outer.pickComplexity == 4)
        }
    }

    // MARK: - map

    @Suite("map")
    struct MapTests {
        @Test("Transforms leaf node")
        func transformsLeaf() {
            let tree = ChoiceTree.just
            let result = tree.map { node in
                if case .just = node { return .getSize(99) }
                return node
            }
            #expect(result == .getSize(99))
        }

        @Test("Recursively transforms group children")
        func transformsGroupChildren() {
            let tree = ChoiceTree.group([.just, .just])
            let result = tree.map { node in
                if case .just = node { return .getSize(0) }
                return node
            }
            #expect(result == .group([.getSize(0), .getSize(0)]))
        }

        @Test("Recursively transforms sequence elements")
        func transformsSequence() {
            let meta = ChoiceMetadata(validRange: 0 ... 5)
            let tree = ChoiceTree.sequence(length: 1, elements: [.just], meta)
            let result = tree.map { node in
                if case .just = node { return .getSize(1) }
                return node
            }
            if case let .sequence(_, elements, _) = result {
                #expect(elements == [.getSize(1)])
            } else {
                Issue.record("Expected sequence")
            }
        }

        @Test("Transforms through branch with isSelected")
        func transformsSelectedBranch() {
            let tree = ChoiceTree.branch(
                fingerprint: 0, weight: 1, id: 0, branchCount: 1,
                choice: .just, isSelected: true
            )
            let result = tree.map { node in
                if case .just = node { return .getSize(2) }
                return node
            }
            #expect(result == .branch(
                fingerprint: 0, weight: 1, id: 0, branchCount: 1,
                choice: .getSize(2), isSelected: true
            ))
        }

        @Test("Transforms through resize")
        func transformsResize() {
            let tree = ChoiceTree.resize(newSize: 50, choices: [.just])
            let result = tree.map { node in
                if case .just = node { return .getSize(3) }
                return node
            }
            if case let .resize(size, choices) = result {
                #expect(size == 50)
                #expect(choices == [.getSize(3)])
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
            let tree = ChoiceTree.sequence(length: 3, elements: [.just], meta)
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
            let tree = ChoiceTree.sequence(length: 3, elements: [.just], meta)
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
            let tree = ChoiceTree.just
            let result = tree.relaxingNonExplicitSequenceLengthRanges()
            #expect(result == tree)
        }
    }

    // MARK: - branchId

    @Suite("branchId")
    struct BranchIdTests {
        @Test("Extracts id from branch")
        func extractsFromBranch() {
            let tree = ChoiceTree.branch(
                fingerprint: 0, weight: 1, id: 42, branchCount: 1,
                choice: .just
            )
            #expect(tree.branchId == 42)
        }

        @Test("Extracts id from selected branch")
        func extractsFromSelectedBranch() {
            let branch = ChoiceTree.branch(
                fingerprint: 0, weight: 1, id: 7, branchCount: 1,
                choice: .just, isSelected: true
            )
            #expect(branch.branchId == 7)
        }

        @Test("Returns nil for non-branch")
        func nilForNonBranch() {
            #expect(ChoiceTree.just.branchId == nil)
            #expect(ChoiceTree.getSize(5).branchId == nil)
        }
    }
}

// MARK: - Shared fixtures

private nonisolated(unsafe) let choiceNode = ChoiceTree.choice(
    ChoiceValue(UInt64(5), tag: .uint64),
    ChoiceMetadata(validRange: 0 ... 10)
)
private nonisolated(unsafe) let branchNode = ChoiceTree.branch(
    fingerprint: 0, weight: 1, id: 1, branchCount: 2,
    choice: .just
)
private nonisolated(unsafe) let justNode = ChoiceTree.just
private nonisolated(unsafe) let groupNode = ChoiceTree.group([justNode])
private nonisolated(unsafe) let getSizeNode = ChoiceTree.getSize(50)
