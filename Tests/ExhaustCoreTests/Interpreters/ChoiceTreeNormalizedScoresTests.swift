import Testing
@testable import ExhaustCore

@Suite("ChoiceTree.normalizedScores")
struct ChoiceTreeNormalizedScoresTests {
    @Test("Single choice at range midpoint scores 0.5")
    func choiceMidpoint() {
        let tree = ChoiceTree.choice(
            .unsigned(50, .uint64),
            ChoiceMetadata(validRange: 0 ... 100)
        )
        let scores = tree.normalizedScores()
        #expect(scores.count == 1)
        #expect(scores[0] == 0.5)
    }

    @Test("Choice at range minimum scores 0")
    func choiceMinimum() {
        let tree = ChoiceTree.choice(
            .unsigned(10, .uint64),
            ChoiceMetadata(validRange: 10 ... 20)
        )
        let scores = tree.normalizedScores()
        #expect(scores.count == 1)
        #expect(scores[0] == 0.0)
    }

    @Test("Choice at range maximum scores 1")
    func choiceMaximum() {
        let tree = ChoiceTree.choice(
            .unsigned(20, .uint64),
            ChoiceMetadata(validRange: 10 ... 20)
        )
        let scores = tree.normalizedScores()
        #expect(scores.count == 1)
        #expect(scores[0] == 1.0)
    }

    @Test("Choice with nil range produces no scores")
    func choiceNilRange() {
        let tree = ChoiceTree.choice(
            .unsigned(42, .uint64),
            ChoiceMetadata(validRange: nil)
        )
        let scores = tree.normalizedScores()
        #expect(scores.isEmpty)
    }

    @Test("Choice with zero-width range produces no scores")
    func choiceZeroWidthRange() {
        let tree = ChoiceTree.choice(
            .unsigned(5, .uint64),
            ChoiceMetadata(validRange: 5 ... 5)
        )
        let scores = tree.normalizedScores()
        #expect(scores.isEmpty)
    }

    @Test("Sequence scores length and recurses into elements")
    func sequenceScores() {
        let element = ChoiceTree.choice(
            .unsigned(75, .uint64),
            ChoiceMetadata(validRange: 0 ... 100)
        )
        let tree = ChoiceTree.sequence(
            length: 3,
            elements: [element, element],
            ChoiceMetadata(validRange: 0 ... 10)
        )
        let scores = tree.normalizedScores()
        #expect(scores.count == 3) // 1 for length + 2 for elements
        #expect(scores[0] == 0.3) // 3/10
        #expect(scores[1] == 0.75)
        #expect(scores[2] == 0.75)
    }

    @Test("Group concatenates children's scores")
    func groupScores() {
        let child1 = ChoiceTree.choice(
            .unsigned(0, .uint64),
            ChoiceMetadata(validRange: 0 ... 100)
        )
        let child2 = ChoiceTree.choice(
            .unsigned(100, .uint64),
            ChoiceMetadata(validRange: 0 ... 100)
        )
        let tree = ChoiceTree.group([child1, child2])
        let scores = tree.normalizedScores()
        #expect(scores.count == 2)
        #expect(scores[0] == 0.0)
        #expect(scores[1] == 1.0)
    }

    @Test("Bind concatenates inner and bound scores")
    func bindScores() {
        let inner = ChoiceTree.choice(
            .unsigned(25, .uint64),
            ChoiceMetadata(validRange: 0 ... 100)
        )
        let bound = ChoiceTree.choice(
            .unsigned(80, .uint64),
            ChoiceMetadata(validRange: 0 ... 100)
        )
        let tree = ChoiceTree.bind(inner: inner, bound: bound)
        let scores = tree.normalizedScores()
        #expect(scores.count == 2)
        #expect(scores[0] == 0.25)
        #expect(scores[1] == 0.80)
    }

    @Test("Branch recurses into selected subtree")
    func branchScores() {
        let subtree = ChoiceTree.choice(
            .unsigned(60, .uint64),
            ChoiceMetadata(validRange: 0 ... 100)
        )
        let tree = ChoiceTree.branch(
            fingerprint: 1,
            weight: 1,
            id: 0,
            branchIDs: [0, 1, 2],
            choice: subtree
        )
        let scores = tree.normalizedScores()
        #expect(scores.count == 1)
        #expect(scores[0] == 0.6)
    }

    @Test("Selected wrapper is transparent")
    func selectedTransparent() {
        let inner = ChoiceTree.choice(
            .unsigned(50, .uint64),
            ChoiceMetadata(validRange: 0 ... 100)
        )
        let tree = ChoiceTree.selected(inner)
        let scores = tree.normalizedScores()
        #expect(scores.count == 1)
        #expect(scores[0] == 0.5)
    }

    @Test("Resize recurses into children")
    func resizeScores() {
        let child = ChoiceTree.choice(
            .unsigned(40, .uint64),
            ChoiceMetadata(validRange: 0 ... 100)
        )
        let tree = ChoiceTree.resize(newSize: 50, choices: [child])
        let scores = tree.normalizedScores()
        #expect(scores.count == 1)
        #expect(scores[0] == 0.4)
    }

    @Test(".just produces no scores")
    func justEmpty() {
        let scores = ChoiceTree.just.normalizedScores()
        #expect(scores.isEmpty)
    }

    @Test(".getSize produces no scores")
    func getSizeEmpty() {
        let scores = ChoiceTree.getSize(50).normalizedScores()
        #expect(scores.isEmpty)
    }
}

@Suite("ComplexityFeatures")
struct ComplexityFeaturesTests {
    @Test("Returns nil for empty scores")
    func emptyScores() {
        #expect(ComplexityFeatures.from([]) == nil)
    }

    @Test("Single element: all stats equal")
    func singleElement() {
        let features = ComplexityFeatures.from([0.5])
        #expect(features != nil)
        #expect(features?.choiceCount == 1)
        #expect(features?.min == 0.5)
        #expect(features?.max == 0.5)
        #expect(features?.mean == 0.5)
        #expect(features?.median == 0.5)
    }

    @Test("Even count: median is average of middle two")
    func evenCountMedian() {
        let features = ComplexityFeatures.from([0.1, 0.3, 0.7, 0.9])
        #expect(features != nil)
        #expect(features?.choiceCount == 4)
        #expect(features?.min == 0.1)
        #expect(features?.max == 0.9)
        #expect(features?.median == 0.5) // (0.3 + 0.7) / 2
    }

    @Test("Odd count: median is middle element")
    func oddCountMedian() {
        let features = ComplexityFeatures.from([0.2, 0.5, 0.8])
        #expect(features != nil)
        #expect(features?.median == 0.5)
    }

    @Test("Mean is computed correctly")
    func meanComputation() {
        let features = ComplexityFeatures.from([0.0, 0.5, 1.0])
        #expect(features != nil)
        #expect(features?.mean == 0.5)
    }
}
