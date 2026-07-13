import ExhaustCore
import Testing

@Suite("Champion-archive distillation tests")
struct ChampionArchiveTests {
    @Test("A shorter admission dethrones the incumbent and evicts it once it holds no cells")
    func championReplacementAndEviction() {
        let corpus = archiveCorpus()
        // The incumbent covers edges 1 and 2 with a three-element sequence.
        #expect(offer(corpus, sequence: sequence(length: 3), edges: [1, 2]) == .admitted(index: 0, tier: .mutable))
        #expect(corpus.mutableTierIndices == [0])

        // A shorter entry takes edge 1 (admitted through fresh edge 3); the incumbent survives on edge 2.
        #expect(offer(corpus, sequence: sequence(length: 2, marker: 1), edges: [1, 3]) == .admitted(index: 1, tier: .mutable))
        #expect(corpus.mutableTierIndices.contains(0))
        #expect(corpus.mutableTierIndices.contains(1))

        // Another short entry takes edge 2 (through fresh edge 4); the incumbent now holds no cell and leaves parent selection.
        #expect(offer(corpus, sequence: sequence(length: 2, marker: 2), edges: [2, 4]) == .admitted(index: 2, tier: .mutable))
        #expect(corpus.mutableTierIndices.contains(0) == false)
        #expect(corpus.mutableTierIndices.contains(1))
        #expect(corpus.mutableTierIndices.contains(2))
    }

    @Test("A longer admission never dethrones a champion")
    func longerEntriesLose() {
        let corpus = archiveCorpus()
        #expect(offer(corpus, sequence: sequence(length: 2), edges: [1]) == .admitted(index: 0, tier: .mutable))
        // Admitted through fresh edge 2, but edge 1's cell stays with the shorter incumbent — and with no cell won, the newcomer stays out of parent selection only if it wins nothing at all; here it champions edge 2.
        #expect(offer(corpus, sequence: sequence(length: 5), edges: [1, 2]) == .admitted(index: 1, tier: .mutable))
        #expect(corpus.mutableTierIndices.contains(0))
        #expect(corpus.mutableTierIndices.contains(1))

        // A third, longer entry hitting only already-championed edges via a new bucket wins no cell and stays out.
        #expect(offer(corpus, sequence: sequence(length: 6), edges: [1, 2], hitCount: 5) == .admitted(index: 2, tier: .mutable))
        #expect(corpus.mutableTierIndices.contains(2) == false)
    }

    @Test("The archive bounds parent selection by covered-edge count")
    func archiveSizeBound() {
        let corpus = archiveCorpus()
        for step in 0 ..< 8 {
            _ = offer(corpus, sequence: sequence(length: 3 + step), edges: [step])
        }
        #expect(corpus.mutableTierIndices.count <= 8)
        #expect(corpus.mutableTierIndices.count == 8)
    }

    @Test("Quarantine releases a champion's cells without letting it back in")
    func quarantineInteraction() {
        let corpus = archiveCorpus()
        let championSequence = sequence(length: 2)
        #expect(offer(corpus, sequence: championSequence, edges: [1]) == .admitted(index: 0, tier: .mutable))
        corpus.quarantine(sequenceHash: ZobristHash.hash(of: championSequence))
        #expect(corpus.mutableTierIndices.isEmpty)

        // A later admission reclaims the released cell even though it is longer than the quarantined champion.
        #expect(offer(corpus, sequence: sequence(length: 4), edges: [1, 2]) == .admitted(index: 1, tier: .mutable))
        #expect(corpus.mutableTierIndices == [1])
    }
}

// MARK: - Helpers

private func archiveCorpus() -> FuzzCorpus {
    var experiments = FuzzExperiments()
    experiments.championArchive = true
    return FuzzCorpus(edgeCount: 16, experiments: experiments)
}

/// A distinct sequence per (length, marker): the marker value keeps equal-length sequences from colliding on the corpus's Zobrist dedup.
private func sequence(length: Int, marker: UInt64 = 0) -> ChoiceSequence {
    var result: ChoiceSequence = [
        .value(ChoiceSequenceValue.Value(choice: ChoiceValue(marker, tag: .uint64), validRange: nil)),
    ]
    result.append(contentsOf: ChoiceSequence(repeating: .just, count: max(0, length - 1)))
    return result
}

private func offer(
    _ corpus: FuzzCorpus,
    sequence: ChoiceSequence,
    edges: [Int],
    hitCount: UInt8 = 1
) -> CorpusAdmission {
    corpus.offer(
        sequence: sequence,
        tree: .just,
        hits: edges.map { (edge: $0, hitCount: hitCount) },
        convergence: 1.0,
        generation: 0,
        phase: .mutation
    )
}
