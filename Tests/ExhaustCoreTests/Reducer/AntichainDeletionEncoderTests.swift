//
//  AntichainDeletionEncoderTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/3/2026.
//

import Testing
@testable import ExhaustCore

@Suite("AntichainDeletionEncoder")
struct AntichainDeletionEncoderTests {
    @Test("Full set accepted on first probe")
    func fullSetAccepted() {
        // Three candidates: deleting all at once works.
        let seq = makeSequence([10, 20, 30, 40, 50])
        let candidates = makeCandidates(
            from: seq,
            indices: [0, 1, 2]
        )

        var encoder = AntichainDeletionEncoder()
        encoder.setCandidates(candidates)
        encoder.start(
            sequence: seq,
            tree: ChoiceTree.just,
            positionRange: 0 ... max(0, seq.count - 1),
            context: ReductionContext()
        )

        // First probe: full set deletion [10, 20, 30] → leaves [40, 50].
        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe != nil)
        if let probe {
            #expect(probe.count == 2)
            #expect(probe.shortLexPrecedes(seq))
        }

        // Accept it — should be done.
        let next = encoder.nextProbe(lastAccepted: true)
        #expect(next == nil)
    }

    @Test("Full set rejected, falls back to halves")
    func fallsBackToHalves() {
        // Four candidates. Full set rejected, but individual halves work.
        let seq = makeSequence([10, 20, 30, 40, 50, 60])
        let candidates = makeCandidates(
            from: seq,
            indices: [0, 1, 2, 3]
        )

        var encoder = AntichainDeletionEncoder()
        encoder.setCandidates(candidates)
        encoder.start(
            sequence: seq,
            tree: ChoiceTree.just,
            positionRange: 0 ... max(0, seq.count - 1),
            context: ReductionContext()
        )

        // Probe 1: full set [10, 20, 30, 40].
        let fullProbe = encoder.nextProbe(lastAccepted: false)
        #expect(fullProbe != nil)

        // Reject full set — should try left half [10, 20].
        let leftProbe = encoder.nextProbe(lastAccepted: false)
        #expect(leftProbe != nil)
        if let leftProbe {
            // Left half deletes indices 0, 1 → leaves [30, 40, 50, 60].
            #expect(leftProbe.count == 4)
        }
    }

    @Test("Single candidates produce no probes")
    func singleCandidateNoProbes() {
        let seq = makeSequence([10, 20])
        let candidates = makeCandidates(from: seq, indices: [0])

        var encoder = AntichainDeletionEncoder()
        encoder.setCandidates(candidates)
        encoder.start(
            sequence: seq,
            tree: ChoiceTree.just,
            positionRange: 0 ... max(0, seq.count - 1),
            context: ReductionContext()
        )

        // Needs > 2 candidates to activate.
        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe == nil)
    }

    @Test("Two candidates produce no probes")
    func twoCandidatesNoProbes() {
        let seq = makeSequence([10, 20, 30])
        let candidates = makeCandidates(from: seq, indices: [0, 1])

        var encoder = AntichainDeletionEncoder()
        encoder.setCandidates(candidates)
        encoder.start(
            sequence: seq,
            tree: ChoiceTree.just,
            positionRange: 0 ... max(0, seq.count - 1),
            context: ReductionContext()
        )

        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe == nil)
    }

    @Test("All probes are shortlex-smaller than input")
    func allProbesShortlexSmaller() {
        let seq = makeSequence([10, 20, 30, 40, 50])
        let candidates = makeCandidates(
            from: seq,
            indices: [0, 1, 2]
        )

        var encoder = AntichainDeletionEncoder()
        encoder.setCandidates(candidates)
        encoder.start(
            sequence: seq,
            tree: ChoiceTree.just,
            positionRange: 0 ... max(0, seq.count - 1),
            context: ReductionContext()
        )

        // Reject everything — collect all probes.
        var probes = [ChoiceSequence]()
        while let probe = encoder.nextProbe(lastAccepted: false) {
            probes.append(probe)
        }

        for probe in probes {
            #expect(probe.shortLexPrecedes(seq))
        }
    }

    @Test("Greedy extension adds candidates after binary split")
    func greedyExtension() {
        // Five candidates. Full rejected, left half [0,1] rejected,
        // single [0] accepted, single [1] rejected.
        // Best from left = [0]. Greedy extends over [1, 2, 3, 4].
        let seq = makeSequence([10, 20, 30, 40, 50, 60, 70])
        let candidates = makeCandidates(
            from: seq,
            indices: [0, 1, 2, 3, 4]
        )

        var encoder = AntichainDeletionEncoder()
        encoder.setCandidates(candidates)
        encoder.start(
            sequence: seq,
            tree: ChoiceTree.just,
            positionRange: 0 ... max(0, seq.count - 1),
            context: ReductionContext()
        )

        // Reject everything until we've seen at least 5 probes
        // (full + left + single-left + single-right + right-half...).
        var probeCount = 0
        while let _ = encoder.nextProbe(lastAccepted: false) {
            probeCount += 1
            if probeCount > 50 { break }
        }

        // Should have produced multiple probes from the binary split
        // and greedy extension phases.
        #expect(probeCount >= 5)
        #expect(probeCount <= 50)
    }

    @Test("Estimated cost is O(n log n)")
    func estimatedCost() {
        let seq = makeSequence([10, 20, 30, 40, 50, 60, 70, 80, 90])
        let candidates = makeCandidates(
            from: seq,
            indices: [0, 1, 2, 3, 4, 5, 6, 7]
        )

        var encoder = AntichainDeletionEncoder()
        encoder.setCandidates(candidates)

        let cost = encoder.estimatedCost(
            sequence: seq,
            tree: ChoiceTree.just,
            positionRange: 0 ... max(0, seq.count - 1),
            context: ReductionContext()
        )

        // 8 candidates, log2(8) = 3, cost = 8 * 3 = 24.
        #expect(cost == 24)
    }
}

// MARK: - Helpers

private func makeSequence(_ values: [UInt64]) -> ChoiceSequence {
    var seq = ChoiceSequence()
    for value in values {
        seq.append(.value(.init(
            choice: .unsigned(value, .uint64),
            validRange: 0 ... UInt64.max,
            isRangeExplicit: false
        )))
    }
    return seq
}

/// Builds candidates where each candidate deletes a single value entry
/// at the given index.
private func makeCandidates(
    from _: ChoiceSequence,
    indices: [Int]
) -> [AntichainDeletionEncoder.Candidate] {
    indices.map { index in
        let span = ChoiceSpan(
            kind: .value(.init(
                choice: .unsigned(0, .uint64),
                validRange: nil
            )),
            range: index ... index,
            depth: 0
        )
        return AntichainDeletionEncoder.Candidate(
            nodeIndex: index,
            spans: [span],
            deletedLength: 1
        )
    }
}
