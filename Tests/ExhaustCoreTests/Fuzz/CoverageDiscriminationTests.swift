import ExhaustCore
import Testing

@Suite("Coverage discrimination math on synthetic signatures")
struct CoverageDiscriminationTests {
    @Test("An edge hit by every failure and no pass ranks first; common code is excluded")
    func rankingSeparatesSignalFromSetup() {
        // Edge 0 is common code (every signature, both sides). Edge 5 is hit by every failure and no pass. Edge 3 is hit by every failure and half the passes.
        let failing = [bits([0, 3, 5]), bits([0, 3, 5])]
        let passing = sample([[0, 3], [0], [0, 3], [0]])

        let ranked = CoverageDiscrimination.rankedEdges(failingSignatures: failing, passing: passing)
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

    @Test("Ranking is bounded by the requested limit")
    func rankingLimit() {
        // Ten edges, each in every failure and no pass; all discriminate maximally.
        let failing = [bits(Array(0 ..< 10))]
        let passing = sample([[20]])
        let ranked = CoverageDiscrimination.rankedEdges(failingSignatures: failing, passing: passing, limit: 4)
        #expect(ranked.count == 4)
        let candidates = CoverageDiscrimination.rankedEdges(failingSignatures: failing, passing: passing)
        #expect(candidates.count == min(10, FuzzTunables.discriminatingEdgeCandidateLimit))
    }

    @Test("No failing signatures yield an empty ranking")
    func rankingEmpty() {
        let ranked = CoverageDiscrimination.rankedEdges(failingSignatures: [], passing: sample([[1, 2]]))
        #expect(ranked.isEmpty)
    }

    @Test("The passing sample counts entries and per-edge hits, ignoring edges outside the domain")
    func passingSampleCounts() {
        let passing = sample([[0, 3], [0], [3, 40]])
        #expect(passing.sampleSize == 3)
        #expect(passing[0] == 2)
        #expect(passing[3] == 2)
        #expect(passing[1] == 0)
        #expect(passing[40] == 0)
    }

    @Test("Full discrimination carries the cluster identity and the ranking")
    func composedDiscrimination() {
        let failing = [bits([0, 3, 5]), bits([0, 3, 5])]
        let discrimination = CoverageDiscrimination.discriminate(
            clusterID: 7,
            failingSignatures: failing,
            passing: sample([[0, 3], [0]])
        )
        #expect(discrimination.clusterID == 7)
        #expect(discrimination.rankedEdges.first?.edge == 5)
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

private func sample(_ entries: [[Int]]) -> PassingSample {
    PassingSample(passingHits: entries.map { edges in edges.map { (edge: $0, hitCount: UInt8(1)) } }, edgeCount: 32)
}
