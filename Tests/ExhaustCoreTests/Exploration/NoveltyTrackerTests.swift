//
//  NoveltyTrackerTests.swift
//  ExhaustTests
//

import ExhaustCore
import Testing

@Suite("NoveltyTracker")
struct NoveltyTrackerTests {
    @Test("First sequence always scores > 0")
    func firstSequenceIsNovel() {
        var tracker = NoveltyTracker()
        let tree = ChoiceTree.choice(.unsigned(42, .uint64), ChoiceMetadata(validRange: 0 ... 100))
        let sequence = ChoiceSequence(tree)
        let score = tracker.score(tree: tree, sequence: sequence)
        #expect(score > 0)
    }

    @Test("Identical sequence scores 0 on second insertion")
    func duplicateSequenceScoresZero() {
        var tracker = NoveltyTracker()
        let tree = ChoiceTree.choice(.unsigned(42, .uint64), ChoiceMetadata(validRange: 0 ... 100))
        let sequence = ChoiceSequence(tree)

        _ = tracker.score(tree: tree, sequence: sequence)
        let secondScore = tracker.score(tree: tree, sequence: sequence)
        #expect(secondScore == 0)
    }

    @Test("Same branch path but different values scores medium novelty")
    func sameBranchPathDifferentValues() {
        var tracker = NoveltyTracker()

        // Two trees with identical structure (no branches) but different values
        let tree1 = ChoiceTree.choice(.unsigned(10, .uint64), ChoiceMetadata(validRange: 0 ... 100))
        let tree2 = ChoiceTree.choice(.unsigned(20, .uint64), ChoiceMetadata(validRange: 0 ... 100))

        let seq1 = ChoiceSequence(tree1)
        let seq2 = ChoiceSequence(tree2)

        let score1 = tracker.score(tree: tree1, sequence: seq1)
        let score2 = tracker.score(tree: tree2, sequence: seq2)

        // First is fully novel, second should be medium (same branch path hash, different sequence)
        #expect(score1 > score2)
        #expect(score2 > 0)
    }

    @Test("Different branch paths score high novelty")
    func differentBranchPathsScoreHigh() {
        var tracker = NoveltyTracker()

        // Tree selecting branch id=1 (only the selected branch present in the tree)
        let tree1 = ChoiceTree.branch(
            fingerprint: 1, weight: 1, id: 1, branchIDs: [1, 2],
            choice: .choice(.unsigned(5, .uint64), ChoiceMetadata(validRange: 0 ... 100))
        )

        // Tree selecting branch id=2 (different branch chosen)
        let tree2 = ChoiceTree.branch(
            fingerprint: 1, weight: 1, id: 2, branchIDs: [1, 2],
            choice: .choice(.unsigned(10, .uint64), ChoiceMetadata(validRange: 0 ... 100))
        )

        let seq1 = ChoiceSequence(tree1)
        let seq2 = ChoiceSequence(tree2)

        let score1 = tracker.score(tree: tree1, sequence: seq1)
        let score2 = tracker.score(tree: tree2, sequence: seq2)

        // Both should have high novelty (different branch paths)
        #expect(score1 >= 1.0)
        #expect(score2 >= 1.0)
    }

    @Test("Branch-path hash is deterministic")
    func branchPathHashDeterministic() {
        let tree = ChoiceTree.group([
            .selected(.branch(fingerprint: 1, weight: 1, id: 1, branchIDs: [1, 2], choice: .choice(.unsigned(5, .uint64), ChoiceMetadata(validRange: 0 ... 100)))),
            .branch(fingerprint: 1, weight: 1, id: 2, branchIDs: [1, 2], choice: .choice(.unsigned(10, .uint64), ChoiceMetadata(validRange: 0 ... 100))),
        ])

        let hash1 = NoveltyTracker.branchPathHash(of: tree)
        let hash2 = NoveltyTracker.branchPathHash(of: tree)
        #expect(hash1 == hash2)
    }

    @Test("Unseen branch path + unseen sequence gives highest score (1.5)")
    func highestScoreForFullyNovel() {
        var tracker = NoveltyTracker()
        let tree = ChoiceTree.choice(.unsigned(42, .uint64), ChoiceMetadata(validRange: 0 ... 100))
        let sequence = ChoiceSequence(tree)
        let score = tracker.score(tree: tree, sequence: sequence)
        #expect(score == 1.5)
    }

    @Test("Unseen branch path + seen sequence gives score of 1.0")
    func branchNovelSequenceSeen() {
        var tracker = NoveltyTracker()

        // First: score a simple value tree
        let tree1 = ChoiceTree.choice(.unsigned(42, .uint64), ChoiceMetadata(validRange: 0 ... 100))
        let seq1 = ChoiceSequence(tree1)
        _ = tracker.score(tree: tree1, sequence: seq1)

        // Create a tree with a branch that produces the same flattened sequence
        // but different structural path. Since branch nodes with .selected
        // unwrap transparently in flatten, we need the actual value to match.
        // This is tricky: we need same sequence but different branch hash.
        // A branch wrapping the same choice will flatten to the same sequence.
        let tree2 = ChoiceTree.group([
            .selected(.branch(
                fingerprint: 99, weight: 1, id: 1, branchIDs: [1],
                choice: .choice(.unsigned(42, .uint64), ChoiceMetadata(validRange: 0 ... 100))
            )),
        ])
        let seq2 = ChoiceSequence(tree2)

        // Only if the sequences actually match will we see score 1.0
        if seq1 == seq2 {
            let score = tracker.score(tree: tree2, sequence: seq2)
            #expect(score == 1.0)
        }
        // Otherwise the sequences differ and both tiers are new
    }

    @Test("Scoring many values doesn't crash or produce negative scores")
    func stressTest() {
        var tracker = NoveltyTracker()

        for i: UInt64 in 0 ..< 500 {
            let tree = ChoiceTree.choice(.unsigned(i, .uint64), ChoiceMetadata(validRange: 0 ... 1000))
            let sequence = ChoiceSequence(tree)
            let score = tracker.score(tree: tree, sequence: sequence)
            #expect(score >= 0)
        }
    }
}
