//
//  SpanExtractionTests.swift
//  ExhaustTests
//
//  Tests for ChoiceSequence.extractContainerSpans and ChoiceSequence.extractValueSpans
//

import Testing
@testable import Exhaust

// MARK: - Helpers

/// Shorthand for building test sequences without the noise of full ChoiceSequenceValue construction
private func val(_ n: UInt64) -> ChoiceSequenceValue {
    .value(.init(choice: .unsigned(n), validRanges: [0...100]))
}

private func branch(_ n: Int) -> ChoiceSequenceValue {
    .branch(.init(choice: .unsigned(UInt64(n)), validRanges: [0...10]))
}

private let seqOpen  = ChoiceSequenceValue.sequence(true)
private let seqClose = ChoiceSequenceValue.sequence(false)
private let grpOpen  = ChoiceSequenceValue.group(true)
private let grpClose = ChoiceSequenceValue.group(false)

private typealias Span = ChoiceSequence.ChoiceSpan

// MARK: - extractContainerSpans

@Suite("Container span extraction tests")
struct ExtractContainerSpansTests {

    @Test("Empty sequence returns no spans")
    func emptySequence() {
        let spans = ChoiceSequence.extractContainerSpans(from: [])
        #expect(spans.isEmpty)
    }

    @Test("Values only returns no spans")
    func valuesOnly() {
        let seq: ChoiceSequence = [val(1), val(2), val(3)]
        let spans = ChoiceSequence.extractContainerSpans(from: seq)
        #expect(spans.isEmpty)
    }

    @Test("Single sequence span")
    func singleSequence() {
        // [V V]
        let seq: ChoiceSequence = [seqOpen, val(1), val(2), seqClose]
        let spans = ChoiceSequence.extractContainerSpans(from: seq)

        #expect(spans.count == 1)
        #expect(spans[0].range == 0...3)
        #expect(spans[0].depth == 0)
        #expect(spans[0].kind == .sequence(true))
    }

    @Test("Single group span")
    func singleGroup() {
        // (V V)
        let seq: ChoiceSequence = [grpOpen, val(1), val(2), grpClose]
        let spans = ChoiceSequence.extractContainerSpans(from: seq)

        #expect(spans.count == 1)
        #expect(spans[0].range == 0...3)
        #expect(spans[0].depth == 0)
        #expect(spans[0].kind == .group(true))
    }

    @Test("Empty sequence container")
    func emptySequenceContainer() {
        // []
        let seq: ChoiceSequence = [seqOpen, seqClose]
        let spans = ChoiceSequence.extractContainerSpans(from: seq)

        #expect(spans.count == 1)
        #expect(spans[0].range == 0...1)
        #expect(spans[0].depth == 0)
    }

    @Test("Empty group container")
    func emptyGroupContainer() {
        // ()
        let seq: ChoiceSequence = [grpOpen, grpClose]
        let spans = ChoiceSequence.extractContainerSpans(from: seq)

        #expect(spans.count == 1)
        #expect(spans[0].range == 0...1)
        #expect(spans[0].depth == 0)
    }

    @Test("Two sequential sequences")
    func twoSequentialSequences() {
        // [V] [V]
        let seq: ChoiceSequence = [seqOpen, val(1), seqClose, seqOpen, val(2), seqClose]
        let spans = ChoiceSequence.extractContainerSpans(from: seq)

        #expect(spans.count == 2)
        // Reversed order means first span in array is the first in the sequence
        #expect(spans[0].range == 3...5)
        #expect(spans[0].depth == 0)
        #expect(spans[1].range == 0...2)
        #expect(spans[1].depth == 0)
    }

    @Test("Nested sequence inside group")
    func nestedSequenceInsideGroup() {
        // ([V V])
        let seq: ChoiceSequence = [grpOpen, seqOpen, val(1), val(2), seqClose, grpClose]
        let spans = ChoiceSequence.extractContainerSpans(from: seq)

        #expect(spans.count == 2)
        // Reversed: outer first, inner second
        #expect(spans[0].range == 0...5)
        #expect(spans[0].depth == 0)
        #expect(spans[0].kind == .group(true))

        #expect(spans[1].range == 1...4)
        #expect(spans[1].depth == 1)
        #expect(spans[1].kind == .sequence(true))
    }

    @Test("Nested group inside sequence")
    func nestedGroupInsideSequence() {
        // [(V)]
        let seq: ChoiceSequence = [seqOpen, grpOpen, val(1), grpClose, seqClose]
        let spans = ChoiceSequence.extractContainerSpans(from: seq)

        #expect(spans.count == 2)
        #expect(spans[0].range == 0...4)
        #expect(spans[0].depth == 0)
        #expect(spans[0].kind == .sequence(true))

        #expect(spans[1].range == 1...3)
        #expect(spans[1].depth == 1)
        #expect(spans[1].kind == .group(true))
    }

    @Test("Triple nesting depth")
    func tripleNesting() {
        // [([V])]
        let seq: ChoiceSequence = [
            seqOpen, grpOpen, seqOpen, val(1), seqClose, grpClose, seqClose
        ]
        let spans = ChoiceSequence.extractContainerSpans(from: seq)

        #expect(spans.count == 3)
        #expect(spans[0].range == 0...6)
        #expect(spans[0].depth == 0)

        #expect(spans[1].range == 1...5)
        #expect(spans[1].depth == 1)

        #expect(spans[2].range == 2...4)
        #expect(spans[2].depth == 2)
    }

    @Test("Sibling containers at same depth")
    func siblingContainers() {
        // ([V] [V])
        let seq: ChoiceSequence = [
            grpOpen,
                seqOpen, val(1), seqClose,
                seqOpen, val(2), seqClose,
            grpClose
        ]
        let spans = ChoiceSequence.extractContainerSpans(from: seq)

        #expect(spans.count == 3)

        // Outer group
        #expect(spans[0].range == 0...7)
        #expect(spans[0].depth == 0)
        #expect(spans[0].kind == .group(true))

        // Second inner sequence (reversed, so later one comes first among siblings)
        #expect(spans[1].range == 4...6)
        #expect(spans[1].depth == 1)
        #expect(spans[1].kind == .sequence(true))

        // First inner sequence
        #expect(spans[2].range == 1...3)
        #expect(spans[2].depth == 1)
        #expect(spans[2].kind == .sequence(true))
    }

    @Test("Mixed values and containers")
    func mixedValuesAndContainers() {
        // V [V (V) V] V
        let seq: ChoiceSequence = [
            val(0),
            seqOpen, val(1), grpOpen, val(2), grpClose, val(3), seqClose,
            val(4)
        ]
        let spans = ChoiceSequence.extractContainerSpans(from: seq)

        #expect(spans.count == 2)

        // Outer sequence
        #expect(spans[0].range == 1...7)
        #expect(spans[0].depth == 0)
        #expect(spans[0].kind == .sequence(true))

        // Inner group
        #expect(spans[1].range == 3...5)
        #expect(spans[1].depth == 1)
        #expect(spans[1].kind == .group(true))
    }

    @Test("Branch markers are ignored")
    func branchMarkersIgnored() {
        // (B V)
        let seq: ChoiceSequence = [grpOpen, branch(0), val(1), grpClose]
        let spans = ChoiceSequence.extractContainerSpans(from: seq)

        #expect(spans.count == 1)
        #expect(spans[0].range == 0...3)
        #expect(spans[0].kind == .group(true))
    }

    @Test("Unmatched closing marker is skipped gracefully")
    func unmatchedClosing() {
        // Just a closing marker with no opening - guard pops empty stack
        let seq: ChoiceSequence = [val(1), seqClose]
        let spans = ChoiceSequence.extractContainerSpans(from: seq)
        #expect(spans.isEmpty)
    }

    @Test("Deeply nested single value")
    func deeplyNestedSingleValue() {
        // ((([V])))
        let seq: ChoiceSequence = [
            grpOpen, grpOpen, grpOpen,
            seqOpen, val(42), seqClose,
            grpClose, grpClose, grpClose,
        ]
        let spans = ChoiceSequence.extractContainerSpans(from: seq)

        #expect(spans.count == 4)
        #expect(spans[0].depth == 0)
        #expect(spans[1].depth == 1)
        #expect(spans[2].depth == 2)
        #expect(spans[3].depth == 3)
        #expect(spans[3].range == 3...5)
        #expect(spans[3].kind == .sequence(true))
    }

    @Test("Container span kind preserves the opening marker type")
    func spanKindPreservesType() {
        let seq: ChoiceSequence = [seqOpen, grpOpen, grpClose, seqClose]
        let spans = ChoiceSequence.extractContainerSpans(from: seq)

        #expect(spans[0].kind == .sequence(true))
        #expect(spans[1].kind == .group(true))
    }

    @Test("Multiple containers at different depths mixed with values")
    func complexNesting() {
        // [V [V] V]
        let seq: ChoiceSequence = [
            seqOpen, val(1), seqOpen, val(2), seqClose, val(3), seqClose
        ]
        let spans = ChoiceSequence.extractContainerSpans(from: seq)

        #expect(spans.count == 2)

        #expect(spans[0].range == 0...6)
        #expect(spans[0].depth == 0)

        #expect(spans[1].range == 2...4)
        #expect(spans[1].depth == 1)
    }
}

// MARK: - extractValueSpans

@Suite("Value span extraction tests")
struct ExtractValueSpansTests {

    @Test("Empty sequence returns no spans")
    func emptySequence() {
        let spans = ChoiceSequence.extractValueSpans(from: [])
        #expect(spans.isEmpty)
    }

    @Test("Single value at start of sequence")
    func singleValue() {
        let seq: ChoiceSequence = [val(42)]
        let spans = ChoiceSequence.extractValueSpans(from: seq)

        #expect(spans.count == 1)
        #expect(spans[0].range == 0...0)
        #expect(spans[0].depth == 0)
    }

    @Test("Multiple consecutive values")
    func consecutiveValues() {
        let seq: ChoiceSequence = [val(1), val(2), val(3)]
        let spans = ChoiceSequence.extractValueSpans(from: seq)

        #expect(spans.count == 3)
        // Reversed, so last value is first in result
        #expect(spans[0].range == 2...2)
        #expect(spans[1].range == 1...1)
        #expect(spans[2].range == 0...0)
        // All at depth 0
        #expect(spans.allSatisfy { $0.depth == 0 })
    }

    @Test("Value immediately after sequence opening")
    func valueAfterSequenceOpen() {
        // [V V]
        let seq: ChoiceSequence = [seqOpen, val(1), val(2), seqClose]
        let spans = ChoiceSequence.extractValueSpans(from: seq)

        // Case (.sequence(true), .value) adds span without incrementing depth
        // Case (.value, .value) adds span
        #expect(spans.count == 2)
        #expect(spans[0].range == 2...2)
        #expect(spans[1].range == 1...1)
    }

    @Test("Value after group opening increments depth but does not create span")
    func valueAfterGroupOpen() {
        // (V)
        let seq: ChoiceSequence = [grpOpen, val(1), grpClose]
        let spans = ChoiceSequence.extractValueSpans(from: seq)

        // (.group(true), .value) matches case 4 → depth++ only, no span
        #expect(spans.isEmpty)
    }

    @Test("Second value inside group is captured at incremented depth")
    func secondValueInsideGroup() {
        // (V V)
        let seq: ChoiceSequence = [grpOpen, val(1), val(2), grpClose]
        let spans = ChoiceSequence.extractValueSpans(from: seq)

        // First value: (.group(true), .value) → depth++ (to 1), no span
        // Second value: (.value, .value) → span at depth 1
        #expect(spans.count == 1)
        #expect(spans[0].range == 2...2)
        #expect(spans[0].depth == 1)
    }

    @Test("No containers, only values")
    func onlyValues() {
        let seq: ChoiceSequence = [val(10), val(20)]
        let spans = ChoiceSequence.extractValueSpans(from: seq)

        #expect(spans.count == 2)
        #expect(spans[0].range == 1...1)
        #expect(spans[1].range == 0...0)
    }

    @Test("Only containers, no values")
    func onlyContainers() {
        let seq: ChoiceSequence = [seqOpen, grpOpen, grpClose, seqClose]
        let spans = ChoiceSequence.extractValueSpans(from: seq)
        #expect(spans.isEmpty)
    }

    @Test("Value after sequence close does not create span")
    func valueAfterSequenceClose() {
        // [V] V
        let seq: ChoiceSequence = [seqOpen, val(1), seqClose, val(2)]
        let spans = ChoiceSequence.extractValueSpans(from: seq)

        // i=1: (.sequence(true), .value) → span at depth 0
        // i=3: (.sequence(false), .value) → case 5: depth -= 1, no span
        #expect(spans.count == 1)
        #expect(spans[0].range == 1...1)
    }

    @Test("Value after group close does not create span")
    func valueAfterGroupClose() {
        // (V V) V
        let seq: ChoiceSequence = [grpOpen, val(1), val(2), grpClose, val(3)]
        let spans = ChoiceSequence.extractValueSpans(from: seq)

        // i=1: (.group(true), .value) → depth++ (to 1)
        // i=2: (.value, .value) → span at depth 1
        // i=4: (.group(false), .value) → depth-- (to 0), no span
        #expect(spans.count == 1)
        #expect(spans[0].range == 2...2)
        #expect(spans[0].depth == 1)
    }

    @Test("Branch marker does not produce value span")
    func branchMarkerNotCaptured() {
        let seq: ChoiceSequence = [branch(0)]
        let spans = ChoiceSequence.extractValueSpans(from: seq)
        #expect(spans.isEmpty)
    }

    @Test("Value after branch marker is not captured")
    func valueAfterBranch() {
        // B V
        let seq: ChoiceSequence = [branch(0), val(1)]
        let spans = ChoiceSequence.extractValueSpans(from: seq)

        // (.branch, .value) → default case, no span
        #expect(spans.isEmpty)
    }

    @Test("Value after branch then another value")
    func valueAfterBranchThenValue() {
        // B V V
        let seq: ChoiceSequence = [branch(0), val(1), val(2)]
        let spans = ChoiceSequence.extractValueSpans(from: seq)

        // i=1: (.branch, .value) → default
        // i=2: (.value, .value) → span at depth 0
        #expect(spans.count == 1)
        #expect(spans[0].range == 2...2)
    }

    @Test("Sequence with branch and values inside group")
    func groupWithBranchAndValues() {
        // (B V V)
        let seq: ChoiceSequence = [grpOpen, branch(0), val(1), val(2), grpClose]
        let spans = ChoiceSequence.extractValueSpans(from: seq)

        // i=1: (.group(true), .branch) → depth++ (to 1)
        // i=2: (.branch, .value) → default
        // i=3: (.value, .value) → span at depth 1
        #expect(spans.count == 1)
        #expect(spans[0].range == 3...3)
        #expect(spans[0].depth == 1)
    }

    @Test("Depth tracking across nested containers")
    func depthTrackingNested() {
        // ([V V])
        let seq: ChoiceSequence = [grpOpen, seqOpen, val(1), val(2), seqClose, grpClose]
        let spans = ChoiceSequence.extractValueSpans(from: seq)

        // i=1: (.group(true), .sequence(true)) → depth++ (to 1)
        // i=2: (.sequence(true), .value) → span at depth 1
        // i=3: (.value, .value) → span at depth 1
        #expect(spans.count == 2)
        #expect(spans[0].range == 3...3)
        #expect(spans[0].depth == 1)
        #expect(spans[1].range == 2...2)
        #expect(spans[1].depth == 1)
    }

    @Test("Values between two sequences")
    func valuesBetweenSequences() {
        // [V] V V [V]
        let seq: ChoiceSequence = [
            seqOpen, val(1), seqClose,
            val(2), val(3),
            seqOpen, val(4), seqClose,
        ]
        let spans = ChoiceSequence.extractValueSpans(from: seq)

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
        let spans = ChoiceSequence.extractValueSpans(from: seq)

        #expect(spans.count == 1)
        #expect(spans[0].kind == v)
    }

    @Test("Each span covers a single index")
    func singleIndexSpans() {
        let seq: ChoiceSequence = [val(1), val(2), val(3)]
        let spans = ChoiceSequence.extractValueSpans(from: seq)

        for span in spans {
            #expect(span.range.lowerBound == span.range.upperBound)
        }
    }

    @Test("Sequence open followed by non-value does not create span")
    func sequenceOpenFollowedByContainer() {
        // [()] — sequence open, then group open
        let seq: ChoiceSequence = [seqOpen, grpOpen, grpClose, seqClose]
        let spans = ChoiceSequence.extractValueSpans(from: seq)
        #expect(spans.isEmpty)
    }

    @Test("Complex realistic sequence")
    func complexRealisticSequence() {
        // Simulates: (B [V V] [V V V])
        let seq: ChoiceSequence = [
            grpOpen,
                branch(1),
                seqOpen, val(10), val(20), seqClose,
                seqOpen, val(30), val(40), val(50), seqClose,
            grpClose,
        ]
        let spans = ChoiceSequence.extractValueSpans(from: seq)

        // i=1:  (.group(true), .branch) → depth++ (to 1)
        // i=2:  (.branch, .sequence(true)) → default
        // i=3:  (.sequence(true), .value) → span at depth 1
        // i=4:  (.value, .value) → span at depth 1
        // i=5:  (.value, .sequence(false)) → default
        // i=6:  (.sequence(false), .sequence(true)) → depth-- (to 0)
        // i=7:  (.sequence(true), .value) → span at depth 0
        // i=8:  (.value, .value) → span at depth 0
        // i=9:  (.value, .value) → span at depth 0
        // i=10: (.value, .sequence(false)) → default
        // i=11: (.sequence(false), .group(false)) → depth-- (to -1)
        #expect(spans.count == 5)

        // Reversed order: last captured first
        #expect(spans[0].range == 9...9)
        #expect(spans[0].depth == 0)

        #expect(spans[1].range == 8...8)
        #expect(spans[1].depth == 0)

        #expect(spans[2].range == 7...7)
        #expect(spans[2].depth == 0)

        #expect(spans[3].range == 4...4)
        #expect(spans[3].depth == 1)

        #expect(spans[4].range == 3...3)
        #expect(spans[4].depth == 1)
    }

    @Test("Value at index zero is always captured")
    func valueAtIndexZero() {
        let seq: ChoiceSequence = [val(1)]
        let spans = ChoiceSequence.extractValueSpans(from: seq)
        #expect(spans.count == 1)
        #expect(spans[0].range == 0...0)
    }

    @Test("Container at index zero followed by value")
    func containerAtIndexZeroFollowedByValue() {
        // Group at start
        let seqG: ChoiceSequence = [grpOpen, val(1), grpClose]
        let spansG = ChoiceSequence.extractValueSpans(from: seqG)
        // (.group(true), .value) → depth++, no span
        #expect(spansG.isEmpty)

        // Sequence at start
        let seqS: ChoiceSequence = [seqOpen, val(1), seqClose]
        let spansS = ChoiceSequence.extractValueSpans(from: seqS)
        // (.sequence(true), .value) → span at depth 0
        #expect(spansS.count == 1)
        #expect(spansS[0].range == 1...1)
    }

    @Test("Depth correctly increments for nested groups")
    func nestedGroupDepth() {
        // ((V V))
        let seq: ChoiceSequence = [grpOpen, grpOpen, val(1), val(2), grpClose, grpClose]
        let spans = ChoiceSequence.extractValueSpans(from: seq)

        // i=1: (.group(true), .group(true)) → depth++ (to 1)
        // i=2: (.group(true), .value) → depth++ (to 2), no span
        // i=3: (.value, .value) → span at depth 2
        #expect(spans.count == 1)
        #expect(spans[0].range == 3...3)
        #expect(spans[0].depth == 2)
    }

    @Test("Depth correctly decrements for nested closings")
    func nestedClosingDepth() {
        // ((V V)) V V
        let seq: ChoiceSequence = [
            grpOpen, grpOpen, val(1), val(2), grpClose, grpClose,
            val(10), val(20),
        ]
        let spans = ChoiceSequence.extractValueSpans(from: seq)

        // i=1: (.group(true), .group(true)) → depth++ (to 1)
        // i=2: (.group(true), .value) → depth++ (to 2), no span
        // i=3: (.value, .value) → span at depth 2
        // i=4: (.value, .group(false)) → default
        // i=5: (.group(false), .group(false)) → depth-- (to 1)
        // i=6: (.group(false), .value) → depth-- (to 0), no span
        // i=7: (.value, .value) → span at depth 0
        #expect(spans.count == 2)
        #expect(spans[0].range == 7...7)
        #expect(spans[0].depth == 0)
        #expect(spans[1].range == 3...3)
        #expect(spans[1].depth == 2)
    }

    @Test("Results are returned in reversed order")
    func reversedOrder() {
        let seq: ChoiceSequence = [val(1), val(2), val(3)]
        let spans = ChoiceSequence.extractValueSpans(from: seq)

        // Original collection order is index 0, 1, 2
        // Reversed means index 2 first
        #expect(spans[0].range == 2...2)
        #expect(spans[1].range == 1...1)
        #expect(spans[2].range == 0...0)
    }
}
