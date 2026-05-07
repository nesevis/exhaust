//
//  ChoiceGraphSpliceTests.swift
//  Exhaust
//

import ExhaustCore
import Testing

@Suite("ChoiceGraph Splice")
struct ChoiceGraphSpliceTests {

    // MARK: - Sequence Removal: Splice vs Rebuild Equivalence

    @Test("Single element removal produces same leaf positions as fresh rebuild")
    func singleElementRemovalEquivalence() {
        let elementA = ChoiceTree.choice(ChoiceValue(10 as UInt64, tag: .uint64), .init(validRange: 0 ... 100))
        let elementB = ChoiceTree.choice(ChoiceValue(20 as UInt64, tag: .uint64), .init(validRange: 0 ... 100))
        let elementC = ChoiceTree.choice(ChoiceValue(30 as UInt64, tag: .uint64), .init(validRange: 0 ... 100))
        let elementD = ChoiceTree.choice(ChoiceValue(40 as UInt64, tag: .uint64), .init(validRange: 0 ... 100))

        let originalTree = ChoiceTree.sequence(
            length: 4,
            elements: [elementA, elementB, elementC, elementD],
            .init(validRange: 0 ... 10, isRangeExplicit: true)
        )

        let graph = ChoiceGraph.build(from: originalTree)

        let seqNodeID = graph.nodes.first {
            if case .sequence = $0.kind { return true }
            return false
        }!.id
        let childToRemove = graph.nodes[seqNodeID].children[1]

        let freshTree = ChoiceTree.sequence(
            length: 3,
            elements: [elementA, elementC, elementD],
            .init(validRange: 0 ... 10, isRangeExplicit: true)
        )

        let application = graph.apply(
            .sequenceElementsRemoved([(seqNodeID: seqNodeID, removedNodeIDs: [childToRemove])]),
            freshTree: freshTree
        )

        #expect(application.requiresFullRebuild == false)
        #expect(graph.isTombstoned(childToRemove))
        #expect(graph.leafPositionsDivergence(in: ChoiceSequence(freshTree)) == nil)
    }

    @Test("Non-contiguous removal produces same leaf positions as fresh rebuild")
    func nonContiguousRemovalEquivalence() {
        let elements = (0 ..< 5).map { index in
            ChoiceTree.choice(
                ChoiceValue(UInt64(index * 10), tag: .uint64),
                .init(validRange: 0 ... 100)
            )
        }

        let originalTree = ChoiceTree.sequence(
            length: 5,
            elements: elements,
            .init(validRange: 0 ... 10, isRangeExplicit: true)
        )

        let graph = ChoiceGraph.build(from: originalTree)

        let seqNodeID = graph.nodes.first {
            if case .sequence = $0.kind { return true }
            return false
        }!.id
        let children = graph.nodes[seqNodeID].children
        let removedIDs = [children[1], children[3]]

        let freshTree = ChoiceTree.sequence(
            length: 3,
            elements: [elements[0], elements[2], elements[4]],
            .init(validRange: 0 ... 10, isRangeExplicit: true)
        )

        let application = graph.apply(
            .sequenceElementsRemoved([(seqNodeID: seqNodeID, removedNodeIDs: removedIDs)]),
            freshTree: freshTree
        )

        #expect(application.requiresFullRebuild == false)
        #expect(graph.isTombstoned(children[1]))
        #expect(graph.isTombstoned(children[3]))
        #expect(graph.isTombstoned(children[0]) == false)
        #expect(graph.isTombstoned(children[2]) == false)
        #expect(graph.isTombstoned(children[4]) == false)
        #expect(graph.leafPositionsDivergence(in: ChoiceSequence(freshTree)) == nil)
    }

    @Test("Removal from nested sequence preserves outer structure")
    func nestedSequenceRemoval() {
        let innerElements = (0 ..< 3).map { index in
            ChoiceTree.choice(
                ChoiceValue(UInt64(index), tag: .uint64),
                .init(validRange: 0 ... 10)
            )
        }
        let innerSeq = ChoiceTree.sequence(
            length: 3,
            elements: innerElements,
            .init(validRange: 0 ... 5, isRangeExplicit: true)
        )

        let outerElement = ChoiceTree.choice(
            ChoiceValue(99 as UInt64, tag: .uint64),
            .init(validRange: 0 ... 100)
        )
        let outerTree = ChoiceTree.group([innerSeq, outerElement])

        let graph = ChoiceGraph.build(from: outerTree)

        let seqNodeID = graph.nodes.first {
            if case .sequence = $0.kind { return true }
            return false
        }!.id
        let children = graph.nodes[seqNodeID].children
        let childToRemove = children[1]

        let shorterInner = ChoiceTree.sequence(
            length: 2,
            elements: [innerElements[0], innerElements[2]],
            .init(validRange: 0 ... 5, isRangeExplicit: true)
        )
        let freshTree = ChoiceTree.group([shorterInner, outerElement])

        let application = graph.apply(
            .sequenceElementsRemoved([(seqNodeID: seqNodeID, removedNodeIDs: [childToRemove])]),
            freshTree: freshTree
        )

        #expect(application.requiresFullRebuild == false)
        #expect(graph.leafPositionsDivergence(in: ChoiceSequence(freshTree)) == nil)
    }

    @Test("Sequence metadata is correct after removal")
    func sequenceMetadataAfterRemoval() {
        let elements = (0 ..< 4).map { index in
            ChoiceTree.choice(
                ChoiceValue(UInt64(index * 10), tag: .uint64),
                .init(validRange: 0 ... 100)
            )
        }

        let originalTree = ChoiceTree.sequence(
            length: 4,
            elements: elements,
            .init(validRange: 0 ... 10, isRangeExplicit: true)
        )

        let graph = ChoiceGraph.build(from: originalTree)

        let seqNodeID = graph.nodes.first {
            if case .sequence = $0.kind { return true }
            return false
        }!.id
        let childToRemove = graph.nodes[seqNodeID].children[2]

        let freshTree = ChoiceTree.sequence(
            length: 3,
            elements: [elements[0], elements[1], elements[3]],
            .init(validRange: 0 ... 10, isRangeExplicit: true)
        )

        let application = graph.apply(
            .sequenceElementsRemoved([(seqNodeID: seqNodeID, removedNodeIDs: [childToRemove])]),
            freshTree: freshTree
        )

        #expect(application.requiresFullRebuild == false)

        guard case let .sequence(metadata) = graph.nodes[seqNodeID].kind else {
            Issue.record("Sequence node lost its kind")
            return
        }
        #expect(metadata.elementCount == 3)
        #expect(metadata.childPositionRanges.count == 3)
        #expect(graph.nodes[seqNodeID].children.count == 3)

        for (index, childID) in graph.nodes[seqNodeID].children.enumerated() {
            #expect(metadata.childIndexByNodeID[childID] == index)
            #expect(graph.nodes[childID].positionRange == metadata.childPositionRanges[index])
        }
    }

    @Test("First element removal shifts all subsequent positions")
    func firstElementRemoval() {
        let elements = (0 ..< 3).map { index in
            ChoiceTree.choice(
                ChoiceValue(UInt64(index), tag: .uint64),
                .init(validRange: 0 ... 10)
            )
        }

        let originalTree = ChoiceTree.sequence(
            length: 3,
            elements: elements,
            .init(validRange: 0 ... 5, isRangeExplicit: true)
        )

        let graph = ChoiceGraph.build(from: originalTree)

        let seqNodeID = graph.nodes.first {
            if case .sequence = $0.kind { return true }
            return false
        }!.id
        let childToRemove = graph.nodes[seqNodeID].children[0]

        let freshTree = ChoiceTree.sequence(
            length: 2,
            elements: [elements[1], elements[2]],
            .init(validRange: 0 ... 5, isRangeExplicit: true)
        )

        let application = graph.apply(
            .sequenceElementsRemoved([(seqNodeID: seqNodeID, removedNodeIDs: [childToRemove])]),
            freshTree: freshTree
        )

        #expect(application.requiresFullRebuild == false)
        #expect(graph.leafPositionsDivergence(in: ChoiceSequence(freshTree)) == nil)
    }

    @Test("Last element removal requires no position shifts for earlier elements")
    func lastElementRemoval() {
        let elements = (0 ..< 3).map { index in
            ChoiceTree.choice(
                ChoiceValue(UInt64(index), tag: .uint64),
                .init(validRange: 0 ... 10)
            )
        }

        let originalTree = ChoiceTree.sequence(
            length: 3,
            elements: elements,
            .init(validRange: 0 ... 5, isRangeExplicit: true)
        )

        let graph = ChoiceGraph.build(from: originalTree)

        let seqNodeID = graph.nodes.first {
            if case .sequence = $0.kind { return true }
            return false
        }!.id
        let children = graph.nodes[seqNodeID].children
        let childToRemove = children[2]
        let firstChildRangeBefore = graph.nodes[children[0]].positionRange
        let secondChildRangeBefore = graph.nodes[children[1]].positionRange

        let freshTree = ChoiceTree.sequence(
            length: 2,
            elements: [elements[0], elements[1]],
            .init(validRange: 0 ... 5, isRangeExplicit: true)
        )

        let application = graph.apply(
            .sequenceElementsRemoved([(seqNodeID: seqNodeID, removedNodeIDs: [childToRemove])]),
            freshTree: freshTree
        )

        #expect(application.requiresFullRebuild == false)
        #expect(graph.nodes[children[0]].positionRange == firstChildRangeBefore)
        #expect(graph.nodes[children[1]].positionRange == secondChildRangeBefore)
        #expect(graph.leafPositionsDivergence(in: ChoiceSequence(freshTree)) == nil)
    }
}
