import ExhaustCore
import Testing

@Suite("Coverage discrimination math on synthetic signatures")
struct CoverageDiscriminationTests {
    @Test("Necessary edges are the intersection across the cluster's signatures")
    func necessaryIntersection() {
        let necessary = CoverageDiscrimination.necessaryEdges(
            of: [bits([1, 2, 3, 7]), bits([1, 3, 7, 9]), bits([0, 1, 3, 7])],
            edgeCount: 16
        )
        #expect(necessary.indices == [1, 3, 7])
    }

    @Test("No signatures yield an empty necessary set")
    func necessaryEmpty() {
        let necessary = CoverageDiscrimination.necessaryEdges(of: [], edgeCount: 16)
        #expect(necessary.isEmpty)
    }

    @Test("An edge hit by every failure and no pass ranks first; common code is excluded")
    func rankingSeparatesSignalFromSetup() {
        // Edge 0 is common code (every signature, both sides). Edge 5 is hit by every failure and no pass. Edge 3 is hit by every failure and half the passes.
        let failing = [bits([0, 3, 5]), bits([0, 3, 5])]
        let passing = [bits([0, 3]), bits([0]), bits([0, 3]), bits([0])]

        let ranked = CoverageDiscrimination.rankedEdges(
            failingSignatures: failing,
            passingSignatures: passing
        )
        #expect(ranked.first?.edge == 5)
        #expect(ranked.first?.failureHitFraction == 1.0)
        #expect(ranked.first?.passingHitFraction == 0.0)
        #expect(ranked.contains { $0.edge == 3 })
        #expect(ranked.contains { $0.edge == 0 } == false)

        if let edgeThree = ranked.first(where: { $0.edge == 3 }) {
            #expect(edgeThree.failureHitFraction == 1.0)
            #expect(edgeThree.passingHitFraction == 0.5)
            #expect(edgeThree.power == 2.0)
        }
    }

    @Test("Ranking is bounded by the tunable limit")
    func rankingLimit() {
        // Ten edges, each in every failure and no pass — all discriminate maximally.
        let failing = [bits(Array(0 ..< 10))]
        let passing = [bits([20])]
        let ranked = CoverageDiscrimination.rankedEdges(
            failingSignatures: failing,
            passingSignatures: passing
        )
        #expect(ranked.count == FuzzTunables.discriminatingEdgeLimit)
    }

    @Test("No failing signatures yield an empty ranking")
    func rankingEmpty() {
        let ranked = CoverageDiscrimination.rankedEdges(
            failingSignatures: [],
            passingSignatures: [bits([1, 2])]
        )
        #expect(ranked.isEmpty)
    }

    @Test("Near-miss differential isolates the edges the closest passing runs lack")
    func nearMissDifferential() {
        let necessary = bits([1, 2, 3, 4, 5])
        // Two near-misses walk most of the path but never edge 5; one distant signature shares nothing.
        let passing = [bits([1, 2, 3, 4]), bits([1, 2, 3]), bits([9, 10])]
        let distinguishing = CoverageDiscrimination.nearMissDifferential(
            necessaryEdges: necessary,
            passingSignatures: passing,
            edgeCount: 16
        )
        #expect(distinguishing.indices == [5])
    }

    @Test("Near-miss differential is empty without passing signatures or necessary edges")
    func nearMissEmptyInputs() {
        #expect(CoverageDiscrimination.nearMissDifferential(
            necessaryEdges: bits([1]),
            passingSignatures: [],
            edgeCount: 16
        ).isEmpty)
        #expect(CoverageDiscrimination.nearMissDifferential(
            necessaryEdges: BitSet(capacity: 16),
            passingSignatures: [bits([1])],
            edgeCount: 16
        ).isEmpty)
    }

    @Test("Full discrimination composes the three analyses")
    func composedDiscrimination() {
        let failing = [bits([0, 3, 5]), bits([0, 3, 5])]
        let passing = [bits([0, 3]), bits([0])]
        let discrimination = CoverageDiscrimination.discriminate(
            clusterID: 7,
            failingSignatures: failing,
            passingSignatures: passing,
            edgeCount: 16
        )
        #expect(discrimination.clusterID == 7)
        #expect(discrimination.necessaryEdges.indices == [0, 3, 5])
        #expect(discrimination.rankedEdges.first?.edge == 5)
        // The nearest pass {0, 3} lacks edge 5; both near-misses lack it.
        #expect(discrimination.nearMissDistinguishingEdges.indices == [5])
    }
}

// MARK: - Helpers

private func bits(_ indices: [Int]) -> BitSet {
    var set = BitSet(capacity: 32)
    for index in indices {
        set.insert(index)
    }
    return set
}
