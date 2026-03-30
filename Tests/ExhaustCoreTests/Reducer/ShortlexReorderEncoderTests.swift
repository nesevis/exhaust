//
//  ShortlexReorderEncoderTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

import Testing
@testable import ExhaustCore

@Suite("ShortlexReorderEncoder")
struct ShortlexReorderEncoderTests {
    @Test("Full sort produces shortlex-smaller candidate")
    func fullSortProducesCandidate() {
        // Sequence: [seq_open, 5, 3, 1, seq_close]
        // Siblings are the three bare values: 5, 3, 1
        // Sorted by shortlex key (unsigned): 1, 3, 5
        let seq: ChoiceSequence = [seqOpen, val(5), val(3), val(1), seqClose]
        let tree = ChoiceTree.just

        var encoder = ShortlexReorderEncoder()
        encoder.start(
            sequence: seq,
            tree: tree,
            positionRange: 0 ... max(0, seq.count - 1),
            context: ReductionContext()
        )

        guard let probe = encoder.nextProbe(lastAccepted: false) else {
            Issue.record("Expected a probe")
            return
        }

        // The probe should have values [1, 3, 5] inside the sequence container.
        #expect(probe[1].unsignedValue == 1)
        #expect(probe[2].unsignedValue == 3)
        #expect(probe[3].unsignedValue == 5)
        #expect(probe.shortLexPrecedes(seq))
    }

    @Test("Already sorted group produces no probes")
    func alreadySortedNoProbes() {
        let seq: ChoiceSequence = [seqOpen, val(1), val(3), val(5), seqClose]
        let tree = ChoiceTree.just

        var encoder = ShortlexReorderEncoder()
        encoder.start(
            sequence: seq,
            tree: tree,
            positionRange: 0 ... max(0, seq.count - 1),
            context: ReductionContext()
        )

        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe == nil)
    }

    @Test("Single element group produces no probes")
    func singleElementNoProbes() {
        let seq: ChoiceSequence = [seqOpen, val(42), seqClose]
        let tree = ChoiceTree.just

        var encoder = ShortlexReorderEncoder()
        encoder.start(
            sequence: seq,
            tree: tree,
            positionRange: 0 ... max(0, seq.count - 1),
            context: ReductionContext()
        )

        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe == nil)
    }

    @Test("Pairwise swap fallback after full sort rejected")
    func pairwiseSwapFallback() {
        // Three elements out of order: [5, 1, 3]
        // Full sort would give [1, 3, 5] — if rejected, pairwise tries (5,1) swap → [1, 5, 3]
        let seq: ChoiceSequence = [seqOpen, val(5), val(1), val(3), seqClose]
        let tree = ChoiceTree.just

        var encoder = ShortlexReorderEncoder()
        encoder.start(
            sequence: seq,
            tree: tree,
            positionRange: 0 ... max(0, seq.count - 1),
            context: ReductionContext()
        )

        // First probe: full sort [1, 3, 5]
        guard let fullSort = encoder.nextProbe(lastAccepted: false) else {
            Issue.record("Expected full sort probe")
            return
        }
        #expect(fullSort[1].unsignedValue == 1)
        #expect(fullSort[2].unsignedValue == 3)
        #expect(fullSort[3].unsignedValue == 5)

        // Reject full sort — should get pairwise swap of (5, 1)
        guard let swap = encoder.nextProbe(lastAccepted: false) else {
            Issue.record("Expected pairwise swap probe")
            return
        }
        #expect(swap[1].unsignedValue == 1)
        #expect(swap[2].unsignedValue == 5)
        #expect(swap[3].unsignedValue == 3)
        #expect(swap.shortLexPrecedes(seq))
    }

    @Test("Estimated cost returns nil when no work")
    func estimatedCostNil() {
        let seq: ChoiceSequence = [seqOpen, val(1), val(2), seqClose]
        let tree = ChoiceTree.just

        let encoder = ShortlexReorderEncoder()
        let cost = encoder.estimatedCost(
            sequence: seq,
            tree: tree,
            positionRange: 0 ... max(0, seq.count - 1),
            context: ReductionContext()
        )
        #expect(cost == nil)
    }

    @Test("Estimated cost returns count of out-of-order groups")
    func estimatedCostNonNil() {
        let seq: ChoiceSequence = [seqOpen, val(3), val(1), seqClose]
        let tree = ChoiceTree.just

        let encoder = ShortlexReorderEncoder()
        let cost = encoder.estimatedCost(
            sequence: seq,
            tree: tree,
            positionRange: 0 ... max(0, seq.count - 1),
            context: ReductionContext()
        )
        #expect(cost == 1)
    }

    @Test("Compound siblings reorder correctly")
    func compoundSiblings() {
        // Two group siblings with single values each: [grp(5), grp(1)]
        // No inner sibling groups to process first.
        // Keys: [5] vs [1] → [1] <shortlex [5] → swap groups.
        let seq: ChoiceSequence = [
            seqOpen,
            grpOpen, val(5), grpClose,
            grpOpen, val(1), grpClose,
            seqClose,
        ]
        let tree = ChoiceTree.just

        var encoder = ShortlexReorderEncoder()
        encoder.start(
            sequence: seq,
            tree: tree,
            positionRange: 0 ... max(0, seq.count - 1),
            context: ReductionContext()
        )

        guard let probe = encoder.nextProbe(lastAccepted: false) else {
            Issue.record("Expected a probe")
            return
        }

        // After reorder: [grp(1), grp(5)]
        #expect(probe[2].unsignedValue == 1)
        #expect(probe[5].unsignedValue == 5)
        #expect(probe.shortLexPrecedes(seq))
    }

    @Test("Equal values produce no probes")
    func equalValuesNoProbes() {
        let seq: ChoiceSequence = [seqOpen, val(7), val(7), val(7), seqClose]
        let tree = ChoiceTree.just

        var encoder = ShortlexReorderEncoder()
        encoder.start(
            sequence: seq,
            tree: tree,
            positionRange: 0 ... max(0, seq.count - 1),
            context: ReductionContext()
        )

        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe == nil)
    }

    @Test("Two-element swap produces shortlex-smaller sequence")
    func twoElementSwap() {
        let seq: ChoiceSequence = [seqOpen, val(10), val(2), seqClose]
        let tree = ChoiceTree.just

        var encoder = ShortlexReorderEncoder()
        encoder.start(
            sequence: seq,
            tree: tree,
            positionRange: 0 ... max(0, seq.count - 1),
            context: ReductionContext()
        )

        guard let probe = encoder.nextProbe(lastAccepted: false) else {
            Issue.record("Expected a probe")
            return
        }
        #expect(probe[1].unsignedValue == 2)
        #expect(probe[2].unsignedValue == 10)
        #expect(probe.shortLexPrecedes(seq))
    }
}

// MARK: - Helpers

private func val(_ n: UInt64) -> ChoiceSequenceValue {
    .value(.init(
        choice: .unsigned(n, .uint64),
        validRange: 0 ... UInt64.max,
        isRangeExplicit: false
    ))
}

private let seqOpen = ChoiceSequenceValue.sequence(true)
private let seqClose = ChoiceSequenceValue.sequence(false)
private let grpOpen = ChoiceSequenceValue.group(true)
private let grpClose = ChoiceSequenceValue.group(false)

private extension ChoiceSequenceValue {
    var unsignedValue: UInt64? {
        switch self {
        case let .value(v):
            v.choice.bitPattern64
        case let .reduced(v):
            v.choice.bitPattern64
        default:
            nil
        }
    }
}
