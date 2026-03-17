//
//  SpanExtractionTests.swift
//  ExhaustTests
//
//  Tests for ChoiceSequence.extractContainerSpans and ChoiceSequence.extractValueSpans
//

import ExhaustCore
import Testing

// MARK: - Helpers

/// Shorthand for building test sequences without the noise of full ChoiceSequenceValue construction
private func val(_ n: UInt64) -> ChoiceSequenceValue {
    .value(.init(choice: .unsigned(n, .uint64), validRange: 0 ... 100))
}

private func reduced(_ n: UInt64) -> ChoiceSequenceValue {
    .reduced(.init(choice: .unsigned(n, .uint64), validRange: 0 ... 100))
}

private func branch(_ n: Int) -> ChoiceSequenceValue {
    .branch(.init(
        id: UInt64(n),
        validIDs: Array(0 ... 9)
    ))
}

private let seqOpen = ChoiceSequenceValue.sequence(true)
private let seqClose = ChoiceSequenceValue.sequence(false)
private let grpOpen = ChoiceSequenceValue.group(true)
private let grpClose = ChoiceSequenceValue.group(false)
private let bindOpen = ChoiceSequenceValue.bind(true)
private let bindClose = ChoiceSequenceValue.bind(false)

private typealias Span = ChoiceSpan

// MARK: - extractValueSpans

@Suite("Value span extraction tests")
struct ExtractValueSpansTests {
    @Test("Empty sequence returns no spans")
    func emptySequence() {
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: [])
        #expect(spans.isEmpty)
    }

    @Test("Single value at start of sequence")
    func singleValue() {
        let seq: ChoiceSequence = [val(42)]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)

        #expect(spans.count == 1)
        #expect(spans[0].range == 0 ... 0)
        #expect(spans[0].depth == 0)
    }

    @Test("Multiple consecutive values")
    func consecutiveValues() {
        let seq: ChoiceSequence = [val(1), val(2), val(3)]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)

        #expect(spans.count == 3)
        #expect(spans[0].range == 0 ... 0)
        #expect(spans[1].range == 1 ... 1)
        #expect(spans[2].range == 2 ... 2)
        // All at depth 0
        #expect(spans.allSatisfy { $0.depth == 0 })
    }

    @Test("Value immediately after sequence opening")
    func valueAfterSequenceOpen() {
        // [V V]
        let seq: ChoiceSequence = [seqOpen, val(1), val(2), seqClose]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)

        // Case (.sequence(true), .value) adds span without incrementing depth
        // Case (.value, .value) adds span
        #expect(spans.count == 2)
        #expect(spans[0].range == 1 ... 1)
        #expect(spans[1].range == 2 ... 2)
    }

    @Test("Value after group opening increments depth but does not create span")
    func valueAfterGroupOpen() {
        // (V)
        let seq: ChoiceSequence = [grpOpen, val(1), grpClose]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)

        // (.group(true), .value) matches case 4 → depth++ only, no span
        #expect(spans.isEmpty)
    }

    @Test("Second value inside group is captured at incremented depth")
    func secondValueInsideGroup() {
        // (V V)
        let seq: ChoiceSequence = [grpOpen, val(1), val(2), grpClose]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)

        // First value: (.group(true), .value) → depth++ (to 1), no span
        // Second value: (.value, .value) → span at depth 1
        #expect(spans.count == 1)
        #expect(spans[0].range == 2 ... 2)
        #expect(spans[0].depth == 1)
    }

    @Test("No containers, only values")
    func onlyValues() {
        let seq: ChoiceSequence = [val(10), val(20)]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)

        #expect(spans.count == 2)
        #expect(spans[0].range == 0 ... 0)
        #expect(spans[1].range == 1 ... 1)
    }

    @Test("Only containers, no values")
    func onlyContainers() {
        let seq: ChoiceSequence = [seqOpen, grpOpen, grpClose, seqClose]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)
        #expect(spans.isEmpty)
    }

    @Test("Value after sequence close does not create span")
    func valueAfterSequenceClose() {
        // [V] V
        let seq: ChoiceSequence = [seqOpen, val(1), seqClose, val(2)]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)

        // i=1: (.sequence(true), .value) → span at depth 0
        // i=3: (.sequence(false), .value) → case 5: depth -= 1, no span
        #expect(spans.count == 1)
        #expect(spans[0].range == 1 ... 1)
    }

    @Test("Value after group close does not create span")
    func valueAfterGroupClose() {
        // (V V) V
        let seq: ChoiceSequence = [grpOpen, val(1), val(2), grpClose, val(3)]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)

        // i=1: (.group(true), .value) → depth++ (to 1)
        // i=2: (.value, .value) → span at depth 1
        // i=4: (.group(false), .value) → depth-- (to 0), no span
        #expect(spans.count == 1)
        #expect(spans[0].range == 2 ... 2)
        #expect(spans[0].depth == 1)
    }

    @Test("Branch marker does not produce value span")
    func branchMarkerNotCaptured() {
        let seq: ChoiceSequence = [branch(0)]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)
        #expect(spans.isEmpty)
    }

    @Test("Value after branch marker is not captured")
    func valueAfterBranch() {
        // B V
        let seq: ChoiceSequence = [branch(0), val(1)]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)

        // (.branch, .value) → default case, no span
        #expect(spans.isEmpty)
    }

    @Test("Value after branch then another value")
    func valueAfterBranchThenValue() {
        // B V V
        let seq: ChoiceSequence = [branch(0), val(1), val(2)]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)

        // i=1: (.branch, .value) → default
        // i=2: (.value, .value) → span at depth 0
        #expect(spans.count == 1)
        #expect(spans[0].range == 2 ... 2)
    }

    @Test("Sequence with branch and values inside group")
    func groupWithBranchAndValues() {
        // (B V V)
        let seq: ChoiceSequence = [grpOpen, branch(0), val(1), val(2), grpClose]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)

        // i=1: (.group(true), .branch) → depth++ (to 1)
        // i=2: (.branch, .value) → default
        // i=3: (.value, .value) → span at depth 1
        #expect(spans.count == 1)
        #expect(spans[0].range == 3 ... 3)
        #expect(spans[0].depth == 1)
    }

    @Test("Depth tracking across nested containers")
    func depthTrackingNested() {
        // ([V V])
        let seq: ChoiceSequence = [grpOpen, seqOpen, val(1), val(2), seqClose, grpClose]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)

        // i=1: (.group(true), .sequence(true)) → depth++ (to 1)
        // i=2: (.sequence(true), .value) → span at depth 1
        // i=3: (.value, .value) → span at depth 1
        #expect(spans.count == 2)
        #expect(spans[0].range == 2 ... 2)
        #expect(spans[0].depth == 2)
        #expect(spans[1].range == 3 ... 3)
        #expect(spans[1].depth == 2)
    }

    @Test("Values between two sequences")
    func valuesBetweenSequences() {
        // [V] V V [V]
        let seq: ChoiceSequence = [
            seqOpen, val(1), seqClose,
            val(2), val(3),
            seqOpen, val(4), seqClose,
        ]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)

        // i=1: (.sequence(true), .value) → span at depth 0
        // i=3: (.sequence(false), .value) → depth-- (-1), no span
        // i=4: (.value, .value) → span at depth -1
        // i=6: (.sequence(true), .value) → span at depth -1
        #expect(spans.count == 3)
    }

    @Test("Span preserves the value kind")
    func spanPreservesValueKind() {
        let v = val(99)
        let seq: ChoiceSequence = [v]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)

        #expect(spans.count == 1)
        #expect(spans[0].kind == v)
    }

    @Test("Each span covers a single index")
    func singleIndexSpans() {
        let seq: ChoiceSequence = [val(1), val(2), val(3)]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)

        for span in spans {
            #expect(span.range.lowerBound == span.range.upperBound)
        }
    }

    @Test("Sequence open followed by non-value does not create span")
    func sequenceOpenFollowedByContainer() {
        // [()] — sequence open, then group open
        let seq: ChoiceSequence = [seqOpen, grpOpen, grpClose, seqClose]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)
        #expect(spans.isEmpty)
    }

    @Test("Value at index zero is always captured")
    func valueAtIndexZero() {
        let seq: ChoiceSequence = [val(1)]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)
        #expect(spans.count == 1)
        #expect(spans[0].range == 0 ... 0)
    }

    @Test("Container at index zero followed by value")
    func containerAtIndexZeroFollowedByValue() {
        // Group at start
        let seqG: ChoiceSequence = [grpOpen, val(1), grpClose]
        let spansG = ChoiceSequence.extractFreeStandingValueSpans(from: seqG)
        // (.group(true), .value) → depth++, no span
        #expect(spansG.isEmpty)

        // Sequence at start
        let seqS: ChoiceSequence = [seqOpen, val(1), seqClose]
        let spansS = ChoiceSequence.extractFreeStandingValueSpans(from: seqS)
        // (.sequence(true), .value) → span at depth 0
        #expect(spansS.count == 1)
        #expect(spansS[0].range == 1 ... 1)
    }

    @Test("Depth correctly increments for nested groups")
    func nestedGroupDepth() {
        // ((V V))
        let seq: ChoiceSequence = [grpOpen, grpOpen, val(1), val(2), grpClose, grpClose]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)

        // i=1: (.group(true), .group(true)) → depth++ (to 1)
        // i=2: (.group(true), .value) → depth++ (to 2), no span
        // i=3: (.value, .value) → span at depth 2
        #expect(spans.count == 1)
        #expect(spans[0].range == 3 ... 3)
        #expect(spans[0].depth == 2)
    }

    @Test("Depth correctly decrements for nested closings")
    func nestedClosingDepth() {
        // ((V V)) V V
        let seq: ChoiceSequence = [
            grpOpen, grpOpen, val(1), val(2), grpClose, grpClose,
            val(10), val(20),
        ]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)

        #expect(spans.count == 2)
        #expect(spans[0].range == 3 ... 3)
        #expect(spans[0].depth == 2)
        #expect(spans[1].range == 7 ... 7)
        #expect(spans[1].depth == 0)
    }

    @Test("Results are returned in reversed order")
    func reversedOrder() {
        let seq: ChoiceSequence = [val(1), val(2), val(3)]
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: seq)

        // Original collection order is index 0, 1, 2
        #expect(spans[0].range == 0 ... 0)
        #expect(spans[1].range == 1 ... 1)
        #expect(spans[2].range == 2 ... 2)
    }
}

// MARK: - extractSequenceBoundarySpans

@Suite("Sequence boundary span extraction tests")
struct ExtractSequenceBoundarySpansTests {
    @Test("Empty sequence returns no spans")
    func emptySequence() {
        let spans = ChoiceSequence.extractSequenceBoundarySpans(from: [])
        #expect(spans.isEmpty)
    }

    @Test("Single flat sequence has no boundaries")
    func singleFlatSequence() {
        // [V V V]
        let seq: ChoiceSequence = [seqOpen, val(1), val(2), val(3), seqClose]
        let spans = ChoiceSequence.extractSequenceBoundarySpans(from: seq)
        #expect(spans.isEmpty)
    }

    @Test("Two sibling sequences at depth 1 are not detected")
    func siblingSequencesAtTopLevel() {
        // [V][V] — depth never exceeds 1
        let seq: ChoiceSequence = [seqOpen, val(1), seqClose, seqOpen, val(2), seqClose]
        let spans = ChoiceSequence.extractSequenceBoundarySpans(from: seq)
        #expect(spans.isEmpty)
    }

    @Test("Two inner sequences inside outer sequence produce one boundary")
    func twoInnerSequences() {
        // [[V][V]]
        let seq: ChoiceSequence = [
            seqOpen,
            seqOpen, val(1), seqClose,
            seqOpen, val(2), seqClose,
            seqClose,
        ]
        let spans = ChoiceSequence.extractSequenceBoundarySpans(from: seq)

        #expect(spans.count == 1)
        // The ][ boundary is at indices 3...4
        #expect(spans[0].range == 3 ... 4)
        #expect(spans[0].depth == 2)
    }

    @Test("Three inner sequences produce two boundaries")
    func threeInnerSequences() {
        // [[V][V][V]]
        let seq: ChoiceSequence = [
            seqOpen, // 0
            seqOpen, val(1), seqClose, // 1, 2, 3
            seqOpen, val(2), seqClose, // 4, 5, 6
            seqOpen, val(3), seqClose, // 7, 8, 9
            seqClose, // 10
        ]
        let spans = ChoiceSequence.extractSequenceBoundarySpans(from: seq)

        #expect(spans.count == 2)
        #expect(spans[0].range == 3 ... 4)
        #expect(spans[1].range == 6 ... 7)
    }

    @Test("Boundary depth reflects sequence nesting depth")
    func boundaryDepthIsCorrect() {
        // [[[V][V]]]
        let seq: ChoiceSequence = [
            seqOpen, // 0, depth 1
            seqOpen, // 1, depth 2
            seqOpen, val(1), seqClose, // 2, 3, 4
            seqOpen, val(2), seqClose, // 5, 6, 7
            seqClose, // 8
            seqClose, // 9
        ]
        let spans = ChoiceSequence.extractSequenceBoundarySpans(from: seq)

        #expect(spans.count == 1)
        #expect(spans[0].range == 4 ... 5)
        // At the point of the ][, sequence depth is 3 (outer + middle + inner closing at 3)
        #expect(spans[0].depth == 3)
    }

    @Test("Groups between sequences do not produce false boundaries")
    func groupsBetweenSequences() {
        // [(V)(V)] — groups, not sequences, so no ][ boundary
        let seq: ChoiceSequence = [
            seqOpen,
            grpOpen, val(1), grpClose,
            grpOpen, val(2), grpClose,
            seqClose,
        ]
        let spans = ChoiceSequence.extractSequenceBoundarySpans(from: seq)
        #expect(spans.isEmpty)
    }

    @Test("Only sequence markers count toward depth, not groups")
    func groupsDoNotAffectSequenceDepth() {
        // ([V][V]) — inner sequences are inside a group, not a sequence
        // sequence depth is only 1 at the ][ boundary
        let seq: ChoiceSequence = [
            grpOpen,
            seqOpen, val(1), seqClose,
            seqOpen, val(2), seqClose,
            grpClose,
        ]
        let spans = ChoiceSequence.extractSequenceBoundarySpans(from: seq)
        #expect(spans.isEmpty)
    }

    @Test("Non-adjacent sequence close and open are not detected")
    func nonAdjacentBoundary() {
        // [[V] V [V]] — value between ] and [
        let seq: ChoiceSequence = [
            seqOpen, // 0
            seqOpen, val(1), seqClose, // 1, 2, 3
            val(99), // 4
            seqOpen, val(2), seqClose, // 5, 6, 7
            seqClose, // 8
        ]
        let spans = ChoiceSequence.extractSequenceBoundarySpans(from: seq)
        #expect(spans.isEmpty)
    }

    @Test("Multiple boundaries at different nesting levels")
    func multipleLevels() {
        // [[[V][V]][[V][V]]]
        let seq: ChoiceSequence = [
            seqOpen, // 0
            seqOpen, // 1
            seqOpen, val(1), seqClose, // 2, 3, 4
            seqOpen, val(2), seqClose, // 5, 6, 7
            seqClose, // 8
            seqOpen, // 9
            seqOpen, val(3), seqClose, // 10, 11, 12
            seqOpen, val(4), seqClose, // 13, 14, 15
            seqClose, // 16
            seqClose, // 17
        ]
        let spans = ChoiceSequence.extractSequenceBoundarySpans(from: seq)

        // Boundaries: 4...5 (depth 3), 8...9 (depth 2), 12...13 (depth 3)
        #expect(spans.count == 3)
        #expect(spans[0].range == 4 ... 5)
        #expect(spans[0].depth == 3)
        #expect(spans[1].range == 8 ... 9)
        #expect(spans[1].depth == 2)
        #expect(spans[2].range == 12 ... 13)
        #expect(spans[2].depth == 3)
    }

    @Test("Values only, no sequences")
    func valuesOnly() {
        let seq: ChoiceSequence = [val(1), val(2), val(3)]
        let spans = ChoiceSequence.extractSequenceBoundarySpans(from: seq)
        #expect(spans.isEmpty)
    }

    @Test("Each boundary span covers exactly two indices")
    func spanCoversExactlyTwoIndices() {
        // [[V][V][V]]
        let seq: ChoiceSequence = [
            seqOpen,
            seqOpen, val(1), seqClose,
            seqOpen, val(2), seqClose,
            seqOpen, val(3), seqClose,
            seqClose,
        ]
        let spans = ChoiceSequence.extractSequenceBoundarySpans(from: seq)

        for span in spans {
            #expect(span.range.upperBound - span.range.lowerBound == 1)
        }
    }

    @Test("Empty inner sequences produce boundary")
    func emptyInnerSequences() {
        // [[][]]
        let seq: ChoiceSequence = [
            seqOpen,
            seqOpen, seqClose,
            seqOpen, seqClose,
            seqClose,
        ]
        let spans = ChoiceSequence.extractSequenceBoundarySpans(from: seq)

        #expect(spans.count == 1)
        #expect(spans[0].range == 2 ... 3)
    }
}

// MARK: - extractSiblingGroups

@Suite("Sibling group extraction tests")
struct ExtractSiblingGroupsTests {
    @Test("Bare values inside sequence produce one group")
    func bareValuesInSequence() {
        // [V V V]
        let seq: ChoiceSequence = [seqOpen, val(3), val(1), val(2), seqClose]
        let groups = ChoiceSequence.extractSiblingGroups(from: seq)

        #expect(groups.count == 1)
        #expect(groups[0].ranges == [1 ... 1, 2 ... 2, 3 ... 3])
        #expect(groups[0].depth == 0)
    }

    @Test("Two sequence siblings inside outer sequence")
    func sequenceSiblingsInsideSequence() {
        // [[VV][VV]]
        let seq: ChoiceSequence = [
            seqOpen,
            seqOpen, val(1), val(2), seqClose,
            seqOpen, val(3), val(4), seqClose,
            seqClose,
        ]
        let groups = ChoiceSequence.extractSiblingGroups(from: seq)

        // The outer sequence has 2 sequence children, and each inner has 2 bare values
        // Outer: group of 2 sequence siblings
        // Each inner: group of 2 bare value siblings
        let outerGroups = groups.filter { $0.depth == 0 }
        #expect(outerGroups.count == 1)
        #expect(outerGroups[0].ranges == [1 ... 4, 5 ... 8])

        let innerGroups = groups.filter { $0.depth == 1 }
        #expect(innerGroups.count == 2)
    }

    @Test("Three group siblings inside sequence")
    func groupSiblingsInsideSequence() {
        // [(V)(V)(V)]
        let seq: ChoiceSequence = [
            seqOpen,
            grpOpen, val(1), grpClose,
            grpOpen, val(2), grpClose,
            grpOpen, val(3), grpClose,
            seqClose,
        ]
        let groups = ChoiceSequence.extractSiblingGroups(from: seq)

        let outerGroups = groups.filter { $0.depth == 0 }
        #expect(outerGroups.count == 1)
        #expect(outerGroups[0].ranges.count == 3)
        #expect(outerGroups[0].ranges == [1 ... 3, 4 ... 6, 7 ... 9])
    }

    @Test("Single child produces no group")
    func singleChild() {
        // [V]
        let seq: ChoiceSequence = [seqOpen, val(1), seqClose]
        let groups = ChoiceSequence.extractSiblingGroups(from: seq)
        #expect(groups.isEmpty)
    }

    @Test("Values inside group are not sequence siblings")
    func valuesInsideGroup() {
        // (V V) — group children, not sequence children
        let seq: ChoiceSequence = [grpOpen, val(1), val(2), grpClose]
        let groups = ChoiceSequence.extractSiblingGroups(from: seq)

        // Groups still have children — 2 bare values in a group
        #expect(groups.count == 1)
        #expect(groups[0].ranges == [1 ... 1, 2 ... 2])
        #expect(groups[0].depth == 0)
    }

    @Test("Mixed children types produce no group")
    func mixedChildrenTypes() {
        // [V [VV]] — one bare value and one sequence container
        let seq: ChoiceSequence = [
            seqOpen,
            val(1),
            seqOpen, val(2), val(3), seqClose,
            seqClose,
        ]
        let groups = ChoiceSequence.extractSiblingGroups(from: seq)

        // Outer has heterogeneous children (bare + sequence) → no group at depth 0
        let outerGroups = groups.filter { $0.depth == 0 }
        #expect(outerGroups.isEmpty)

        // Inner sequence has 2 bare values → one group at depth 1
        let innerGroups = groups.filter { $0.depth == 1 }
        #expect(innerGroups.count == 1)
    }

    @Test("Already sorted group is still extracted")
    func alreadySortedGroupExtracted() {
        // [V V V] with values in order
        let seq: ChoiceSequence = [seqOpen, val(1), val(2), val(3), seqClose]
        let groups = ChoiceSequence.extractSiblingGroups(from: seq)

        #expect(groups.count == 1)
        #expect(groups[0].ranges.count == 3)
    }

    @Test("Empty sequence returns no groups")
    func emptySequence() {
        let groups = ChoiceSequence.extractSiblingGroups(from: [])
        #expect(groups.isEmpty)
    }

    @Test("Branch markers between siblings are ignored")
    func branchMarkersIgnored() {
        // (B V V)
        let seq: ChoiceSequence = [grpOpen, branch(0), val(1), val(2), grpClose]
        let groups = ChoiceSequence.extractSiblingGroups(from: seq)

        #expect(groups.count == 1)
        #expect(groups[0].ranges == [2 ... 2, 3 ... 3])
    }

    @Test("Nested groups each produce their own sibling group")
    func nestedGroupsSiblings() {
        // [[(V)(V)][(V)(V)]]
        let seq: ChoiceSequence = [
            seqOpen,
            seqOpen, grpOpen, val(1), grpClose, grpOpen, val(2), grpClose, seqClose,
            seqOpen, grpOpen, val(3), grpClose, grpOpen, val(4), grpClose, seqClose,
            seqClose,
        ]
        let groups = ChoiceSequence.extractSiblingGroups(from: seq)

        // Depth 0: 2 sequence siblings
        let depth0 = groups.filter { $0.depth == 0 }
        #expect(depth0.count == 1)
        #expect(depth0[0].ranges.count == 2)

        // Depth 1: 2 group siblings in each inner sequence = 2 groups
        let depth1 = groups.filter { $0.depth == 1 }
        #expect(depth1.count == 2)
    }
}

// MARK: - extractSequenceElementSpans

@Suite("Sequence element span extraction tests")
struct ExtractSequenceElementSpansTests {
    @Test("Group-wrapped elements inside bind-nested sequence are detected")
    func groupWrappedElementsInBindNestedSequence() {
        // Coupling pattern with group-wrapped elements: { V [ (V) (V) (V) ] }
        let seq: ChoiceSequence = [
            bindOpen,                                   // 0
            val(2),                                     // 1  — bound index (inner choice)
            seqOpen,                                    // 2
            grpOpen, val(10), grpClose,                 // 3, 4, 5
            grpOpen, val(20), grpClose,                 // 6, 7, 8
            grpOpen, val(30), grpClose,                 // 9, 10, 11
            seqClose,                                   // 12
            bindClose,                                  // 13
        ]
        let spans = ChoiceSequence.extractSequenceElementSpans(from: seq)

        // Three group-wrapped elements, each detected as a sequence element span
        #expect(spans.count == 3)
        #expect(spans[0].range == 3 ... 5)
        #expect(spans[1].range == 6 ... 8)
        #expect(spans[2].range == 9 ... 11)
    }

    @Test("Bare-value elements inside bind-nested sequence are detected")
    func bareValueElementsInBindNestedSequence() {
        // Coupling pattern with bare values: { V [ V V V ] }
        // This is what arrays of simple types (Int, UInt, etc.) produce.
        let seq: ChoiceSequence = [
            bindOpen,                                   // 0
            val(2),                                     // 1  — bound index (inner choice)
            seqOpen,                                    // 2
            val(10),                                    // 3
            val(20),                                    // 4
            val(30),                                    // 5
            seqClose,                                   // 6
            bindClose,                                  // 7
        ]
        let spans = ChoiceSequence.extractSequenceElementSpans(from: seq)

        // Three bare-value elements — each should be a single-index span.
        // BUG: currently returns empty because extractSequenceElementSpans
        // only recognizes group(true)...group(false) pairs, not bare values.
        #expect(spans.count == 3)
        #expect(spans[0].range == 3 ... 3)
        #expect(spans[1].range == 4 ... 4)
        #expect(spans[2].range == 5 ... 5)
    }

    @Test("Bare-value elements in flat sequence are detected")
    func bareValueElementsInFlatSequence() {
        // Simpler case without bind wrapping: [ V V V ]
        let seq: ChoiceSequence = [
            seqOpen,                                    // 0
            val(10),                                    // 1
            val(20),                                    // 2
            val(30),                                    // 3
            seqClose,                                   // 4
        ]
        let spans = ChoiceSequence.extractSequenceElementSpans(from: seq)

        // Three bare-value elements directly inside a sequence
        #expect(spans.count == 3)
        #expect(spans[0].range == 1 ... 1)
        #expect(spans[1].range == 2 ... 2)
        #expect(spans[2].range == 3 ... 3)
    }

    @Test("Group-wrapped elements in flat sequence are detected")
    func groupWrappedElementsInFlatSequence() {
        // Baseline: [ (V) (V) ]
        let seq: ChoiceSequence = [
            seqOpen,                                    // 0
            grpOpen, val(10), grpClose,                 // 1, 2, 3
            grpOpen, val(20), grpClose,                 // 4, 5, 6
            seqClose,                                   // 7
        ]
        let spans = ChoiceSequence.extractSequenceElementSpans(from: seq)

        #expect(spans.count == 2)
        #expect(spans[0].range == 1 ... 3)
        #expect(spans[1].range == 4 ... 6)
    }

    @Test("Empty sequence returns no element spans")
    func emptySequence() {
        let spans = ChoiceSequence.extractSequenceElementSpans(from: [])
        #expect(spans.isEmpty)
    }

    @Test("Sequence with no elements returns no spans")
    func emptyInnerSequence() {
        // []
        let seq: ChoiceSequence = [seqOpen, seqClose]
        let spans = ChoiceSequence.extractSequenceElementSpans(from: seq)
        #expect(spans.isEmpty)
    }

    @Test("Mixed bare and group-wrapped elements are all detected")
    func mixedBareAndGroupWrapped() {
        // [ V (V) V ]
        let seq: ChoiceSequence = [
            seqOpen,                                    // 0
            val(10),                                    // 1
            grpOpen, val(20), grpClose,                 // 2, 3, 4
            val(30),                                    // 5
            seqClose,                                   // 6
        ]
        let spans = ChoiceSequence.extractSequenceElementSpans(from: seq)

        #expect(spans.count == 3)
        #expect(spans[0].range == 1 ... 1)
        #expect(spans[1].range == 2 ... 4)
        #expect(spans[2].range == 5 ... 5)
    }
}
