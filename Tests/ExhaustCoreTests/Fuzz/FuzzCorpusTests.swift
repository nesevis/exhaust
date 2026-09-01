import ExhaustCore
import Testing

@Suite("FuzzCorpus admission and parent selection tests")
struct FuzzCorpusTests {
    @Test("First candidate with any coverage is admitted")
    func firstAdmission() {
        let corpus = FuzzCorpus(edgeCount: 10)
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

    @Test("A discarded entry is admitted on novelty and weighted at a third of a valid one for parent selection")
    func discardedEntryEnergy() {
        let corpus = FuzzCorpus(edgeCount: 10)
        let valid = corpus.offer(
            sequence: sequence(length: 1),
            tree: .just,
            hits: [(edge: 3, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling
        )
        let discarded = corpus.offer(
            sequence: sequence(length: 2),
            tree: .just,
            hits: [(edge: 4, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling,
            propertyDiscarded: true
        )
        guard case let .admitted(validIndex, _) = valid, case let .admitted(discardedIndex, .mutable) = discarded else {
            Issue.record("expected both entries admitted, the discard to the mutable tier: \(valid), \(discarded)")
            return
        }
        // Same rarity (one unique edge each), same novelty bonus, so the only difference is the discard energy.
        #expect(corpus.score(at: discardedIndex) == corpus.score(at: validIndex) * FuzzTunables.discardParentEnergy)
        #expect(corpus.entries[discardedIndex].propertyDiscarded)
        #expect(corpus.passingSignatures.count == 1, "a discard is neither a pass nor a failure for discrimination")
    }

    @Test("Duplicate choice sequences are rejected before coverage math")
    func duplicateRejection() {
        let corpus = FuzzCorpus(edgeCount: 10)
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

    @Test("Precomputed sequence hash preserves duplicate detection")
    func precomputedHashDuplicateRejection() {
        let corpus = FuzzCorpus(edgeCount: 10)
        let candidate = sequence(length: 2)
        _ = corpus.offer(
            sequence: candidate,
            tree: .just,
            hits: [(edge: 1, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling,
            precomputedHash: ZobristHash.hash(of: candidate)
        )
        let duplicate = corpus.offer(
            sequence: candidate,
            tree: .just,
            hits: [(edge: 9, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling
        )
        #expect(duplicate == .rejectedDuplicate)
    }

    @Test("Candidate covering only known (edge, bucket) pairs is rejected")
    func notNovelRejection() {
        let corpus = FuzzCorpus(edgeCount: 10)
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
        let corpus = FuzzCorpus(edgeCount: 10)
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
        let corpus = FuzzCorpus(edgeCount: 10)
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
        let corpus = FuzzCorpus(edgeCount: 10)
        let discovery = corpus.offer(
            sequence: sequence(length: 1),
            tree: .just,
            hits: [(edge: 1, hitCount: 1)],
            convergence: 0.49,
            generation: 0,
            phase: .mutation
        )
        #expect(discovery == .admitted(index: 0, tier: .discovery))
        #expect(corpus.mutableTierIndices.isEmpty)

        let mutable = corpus.offer(
            sequence: sequence(length: 2),
            tree: .just,
            hits: [(edge: 2, hitCount: 1)],
            convergence: 0.5,
            generation: 0,
            phase: .mutation
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
            phase: .mutation
        )
        #expect(rejected == .rejectedNotNovel)
    }

    @Test("Boundary-credit admissions with one shared signature do not grow the invalidation index")
    func invalidationIndexStaysBoundedUnderBoundaryCredit() {
        // Screening rows enter on boundary credit without coverage novelty, so a low-edge target admits every row with the same signature. Indexing each of them for score invalidation made admission walk the whole corpus per edge; only parent-eligible entries (champion-cell holders) have a score anyone reads.
        let corpus = FuzzCorpus(edgeCount: 16)
        let sharedHits = (0 ..< 12).map { (edge: $0, hitCount: UInt8(1)) }
        let rowCount = 2000
        for row in 0 ..< rowCount {
            let admission = corpus.offer(
                sequence: distinctSequence(row),
                tree: .just,
                hits: sharedHits,
                convergence: 1.0,
                generation: 0,
                phase: .screening,
                isBoundaryDerived: true
            )
            #expect(admission.isAdmitted)
        }
        #expect(corpus.entries.count == rowCount)
        #expect(corpus.coveredEdgeCount == 12)
        // Every row covers the same 12 edges, so one shortlex-minimal champion holds every cell and the index carries at most that champion per edge. The bound allows every parent-eligible entry to be indexed once per edge; it must not scale with the corpus.
        #expect(corpus.invalidationIndexSize <= corpus.mutableTierIndices.count * sharedHits.count)
        #expect(corpus.invalidationIndexSize < rowCount)
    }

    @Test("Rarity decays as more entries cover an edge")
    func rarityDecay() {
        let corpus = FuzzCorpus(edgeCount: 10)
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
        let corpus = FuzzCorpus(edgeCount: 10)
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
        #expect(corpus.score(at: 0) == baseScore * FuzzTunables.provisionalFailureBoost)

        corpus.upgradeFailureBoost(
            atParentIndex: 0,
            isNewCluster: true,
            clusterInstanceCount: 1,
            clusterCapReached: false
        )
        #expect(corpus.score(at: 0) == baseScore * FuzzTunables.newClusterFailureBoost)

        corpus.upgradeFailureBoost(
            atParentIndex: 0,
            isNewCluster: false,
            clusterInstanceCount: 1,
            clusterCapReached: false
        )
        #expect(corpus.score(at: 0) == baseScore * FuzzTunables.existingClusterFailureBoost)

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
        let corpus = FuzzCorpus(edgeCount: 10)
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
            phase: .mutation
        )
        for draw in [0.0, 0.3, 0.7, 0.999] {
            let pick = try #require(corpus.pickParent(random: draw))
            #expect(pick.index != 2)
        }
    }
}

// MARK: - Helpers

/// A distinct choice sequence per length, enough to give the corpus distinct Zobrist hashes.
/// A sequence unique per `index`, so repeated offers are not rejected as duplicates.
private func distinctSequence(_ index: Int) -> ChoiceSequence {
    [.value(ChoiceSequenceValue.Value(choice: ChoiceValue(UInt64(index), tag: .uint64), validRange: nil, isRangeExplicit: false))]
}

private func sequence(length: Int) -> ChoiceSequence {
    ChoiceSequence(repeating: .just, count: length)
}
