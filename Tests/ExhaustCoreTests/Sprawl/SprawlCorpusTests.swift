import ExhaustCore
import Testing

@Suite("SprawlCorpus admission and parent selection tests")
struct SprawlCorpusTests {
    @Test("First candidate with any coverage is admitted")
    func firstAdmission() {
        let corpus = SprawlCorpus(edgeCount: 10)
        let admission = corpus.offer(
            sequence: sequence(length: 1),
            tree: .just,
            hits: [(edge: 3, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .screening
        )
        #expect(admission == .admitted(index: 0, tier: .mutable))
        #expect(corpus.entries.count == 1)
        #expect(corpus.coveredEdgeCount == 1)
    }

    @Test("Duplicate choice sequences are rejected before coverage math")
    func duplicateRejection() {
        let corpus = SprawlCorpus(edgeCount: 10)
        _ = corpus.offer(
            sequence: sequence(length: 2),
            tree: .just,
            hits: [(edge: 1, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling
        )
        let second = corpus.offer(
            sequence: sequence(length: 2),
            tree: .just,
            hits: [(edge: 9, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling
        )
        #expect(second == .rejectedDuplicate)
    }

    @Test("Candidate covering only known (edge, bucket) pairs is rejected")
    func notNovelRejection() {
        let corpus = SprawlCorpus(edgeCount: 10)
        _ = corpus.offer(
            sequence: sequence(length: 1),
            tree: .just,
            hits: [(edge: 1, hitCount: 1), (edge: 2, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling
        )
        let rejected = corpus.offer(
            sequence: sequence(length: 2),
            tree: .just,
            hits: [(edge: 1, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling
        )
        #expect(rejected == .rejectedNotNovel)
    }

    @Test("New hit-count bucket on a known edge counts as novelty")
    func bucketTransitionNovelty() {
        let corpus = SprawlCorpus(edgeCount: 10)
        _ = corpus.offer(
            sequence: sequence(length: 1),
            tree: .just,
            hits: [(edge: 1, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling
        )
        // Same edge, hit count 130 lands in the 128+ bucket — novel despite no new edge.
        let admitted = corpus.offer(
            sequence: sequence(length: 2),
            tree: .just,
            hits: [(edge: 1, hitCount: 130)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling
        )
        #expect(admitted == .admitted(index: 1, tier: .mutable))
        // Hit count 2 is bucket 1 — also unseen for this edge.
        let alsoAdmitted = corpus.offer(
            sequence: sequence(length: 3),
            tree: .just,
            hits: [(edge: 1, hitCount: 2)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling
        )
        #expect(alsoAdmitted == .admitted(index: 2, tier: .mutable))
        // Hit count 3 in bucket 2, unseen; but hit count 1 again is not.
        let rejected = corpus.offer(
            sequence: sequence(length: 4),
            tree: .just,
            hits: [(edge: 1, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling
        )
        #expect(rejected == .rejectedNotNovel)
    }

    @Test("Boundary-derived candidate is admitted without coverage novelty")
    func boundaryDerivedAdmission() {
        let corpus = SprawlCorpus(edgeCount: 10)
        _ = corpus.offer(
            sequence: sequence(length: 1),
            tree: .just,
            hits: [(edge: 1, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .screening
        )
        let admitted = corpus.offer(
            sequence: sequence(length: 2),
            tree: .just,
            hits: [(edge: 1, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .screening,
            isBoundaryDerived: true
        )
        #expect(admitted == .admitted(index: 1, tier: .mutable))
    }

    @Test("Convergence below the threshold routes to the discovery tier")
    func tierRouting() {
        let corpus = SprawlCorpus(edgeCount: 10)
        let discovery = corpus.offer(
            sequence: sequence(length: 1),
            tree: .just,
            hits: [(edge: 1, hitCount: 1)],
            convergence: 0.49,
            generation: 0,
            phase: .sprawl
        )
        #expect(discovery == .admitted(index: 0, tier: .discovery))
        #expect(corpus.mutableTierIndices.isEmpty)

        let mutable = corpus.offer(
            sequence: sequence(length: 2),
            tree: .just,
            hits: [(edge: 2, hitCount: 1)],
            convergence: 0.5,
            generation: 0,
            phase: .sprawl
        )
        #expect(mutable == .admitted(index: 1, tier: .mutable))
        #expect(corpus.mutableTierIndices == [1])

        // Discovery-tier entries still contribute coverage credit and rarity counts.
        #expect(corpus.coveredEdgeCount == 2)
        let rejected = corpus.offer(
            sequence: sequence(length: 3),
            tree: .just,
            hits: [(edge: 1, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .sprawl
        )
        #expect(rejected == .rejectedNotNovel)
    }

    @Test("Rarity decays as more entries cover an edge")
    func rarityDecay() {
        let corpus = SprawlCorpus(edgeCount: 10)
        _ = corpus.offer(
            sequence: sequence(length: 1),
            tree: .just,
            hits: [(edge: 1, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling
        )
        let initialScore = corpus.score(at: 0)
        // Entry 0 uniquely covers edge 1: rarity 1, novelty bonus 1 → score 2.
        #expect(initialScore == 2.0)

        // A second entry covering edge 1 (novel via edge 2) halves entry 0's rarity terms.
        _ = corpus.offer(
            sequence: sequence(length: 2),
            tree: .just,
            hits: [(edge: 1, hitCount: 1), (edge: 2, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling
        )
        #expect(corpus.score(at: 0) == 1.0)
        // Entry 1: rarity 1/2 + 1, novelty bonus 1 (introduced edge 2 only) → 2.5.
        #expect(corpus.score(at: 1) == 2.5)
    }

    @Test("Failure boosts multiply the score and upgrade after classification")
    func failureBoosts() {
        let corpus = SprawlCorpus(edgeCount: 10)
        _ = corpus.offer(
            sequence: sequence(length: 1),
            tree: .just,
            hits: [(edge: 1, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling
        )
        let baseScore = corpus.score(at: 0)

        corpus.applyProvisionalFailureBoost(toParentAt: 0)
        #expect(corpus.score(at: 0) == baseScore * SprawlTunables.provisionalFailureBoost)

        corpus.upgradeFailureBoost(
            atParentIndex: 0,
            isNewCluster: true,
            clusterInstanceCount: 1,
            clusterCapReached: false
        )
        #expect(corpus.score(at: 0) == baseScore * SprawlTunables.newClusterFailureBoost)

        corpus.upgradeFailureBoost(
            atParentIndex: 0,
            isNewCluster: false,
            clusterInstanceCount: 1,
            clusterCapReached: false
        )
        #expect(corpus.score(at: 0) == baseScore * SprawlTunables.existingClusterFailureBoost)

        // The existing-cluster boost decays toward 1 as the cluster grows.
        corpus.upgradeFailureBoost(
            atParentIndex: 0,
            isNewCluster: false,
            clusterInstanceCount: 4,
            clusterCapReached: false
        )
        #expect(corpus.score(at: 0) == baseScore * 1.25)

        // A capped cluster stops contributing densification entirely.
        corpus.upgradeFailureBoost(
            atParentIndex: 0,
            isNewCluster: false,
            clusterInstanceCount: 100,
            clusterCapReached: true
        )
        #expect(corpus.score(at: 0) == baseScore)
    }

    @Test("Parent pick is empty on an empty mutable tier and weighted otherwise")
    func parentPick() throws {
        let corpus = SprawlCorpus(edgeCount: 10)
        #expect(corpus.pickParent(random: 0.5) == nil)

        _ = corpus.offer(
            sequence: sequence(length: 1),
            tree: .just,
            hits: [(edge: 1, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling
        )
        _ = corpus.offer(
            sequence: sequence(length: 2),
            tree: .just,
            hits: [(edge: 2, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling
        )
        // Equal scores: draws below 0.5 pick entry 0, above pick entry 1.
        let low = try #require(corpus.pickParent(random: 0.1))
        #expect(low.index == 0)
        let high = try #require(corpus.pickParent(random: 0.9))
        #expect(high.index == 1)

        // Boosting entry 1 shifts the split point: entry 1 now holds 8/9 of the weight.
        corpus.upgradeFailureBoost(
            atParentIndex: 1,
            isNewCluster: true,
            clusterInstanceCount: 1,
            clusterCapReached: false
        )
        let boosted = try #require(corpus.pickParent(random: 0.2))
        #expect(boosted.index == 1)
        let stillLow = try #require(corpus.pickParent(random: 0.05))
        #expect(stillLow.index == 0)

        // Discovery-tier entries are never picked.
        _ = corpus.offer(
            sequence: sequence(length: 3),
            tree: .just,
            hits: [(edge: 3, hitCount: 1)],
            convergence: 0.1,
            generation: 0,
            phase: .sprawl
        )
        for draw in [0.0, 0.3, 0.7, 0.999] {
            let pick = try #require(corpus.pickParent(random: draw))
            #expect(pick.index != 2)
        }
    }
}

// MARK: - Helpers

/// A distinct choice sequence per length, enough to give the corpus distinct Zobrist hashes.
private func sequence(length: Int) -> ChoiceSequence {
    ChoiceSequence(repeating: .just, count: length)
}
