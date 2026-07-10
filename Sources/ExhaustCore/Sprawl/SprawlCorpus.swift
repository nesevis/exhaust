// The corpus of coverage-interesting inputs driving parent selection during sprawl.

/// One accepted input: its choice sequence, coverage signature, and parent-selection state.
package struct CorpusEntry {
    /// The flattened choice sequence — the mutation substrate.
    package let sequence: ChoiceSequence

    /// The choice tree behind `sequence`, kept as the guided-materialisation fallback for mutations of this entry.
    package let tree: ChoiceTree

    /// The edges hit during this entry's property evaluation.
    package let signature: BitSet

    /// The materialiser's convergence ratio for this entry; decides tier membership.
    package let convergence: Double

    /// Mutation distance from a phase-1/2 root: roots are 0, a mutation of a parent is `parent.generation + 1`.
    package let generation: Int

    /// The phase that produced this entry.
    package let phase: SprawlPhase

    /// Zobrist hash of `sequence`, the corpus-wide dedup key.
    package let hash: UInt64

    /// The edges this entry was first to cover, corpus-wide. The novelty bonus is rarity over these edges, so it decays automatically as other entries accumulate hits on them.
    let introducedEdges: [Int]

    /// Multiplier on the entry's parent-selection score from failures among its children. 1 when no child failed; see ``SprawlTunables`` for the provisional and cluster-aware values.
    var failureBoost: Double = 1.0
}

/// Which tier an admitted entry landed in.
package enum CorpusTier: Sendable, Equatable {
    /// Eligible for parent selection; mutations inherit real structure.
    case mutable
    /// Retained for coverage credit and rarity counts, but not picked as a mutation root — mutations would mostly hit PRNG fallback.
    case discovery
}

/// The verdict on a candidate offered to the corpus.
package enum CorpusAdmission: Equatable {
    /// Accepted into the given tier, stored at the given index.
    case admitted(index: Int, tier: CorpusTier)
    /// An entry with an identical choice sequence already exists.
    case rejectedDuplicate
    /// The candidate covers nothing the corpus has not already seen (no new edge, no new hit-count bucket) and carries no boundary-derived credit.
    case rejectedNotNovel
}

/// Accumulates coverage-interesting inputs and answers "which parent should sprawl mutate next?"
///
/// Single-threaded by design: the exploration loop owns the corpus and touches it between attempts, so no synchronisation is needed on the hot path. Failure-weight updates arriving from completed reduction Tasks must be routed through the owning loop rather than calling in from another thread.
///
/// ## Acceptance
///
/// A candidate enters when its signature contains a new edge or a new (edge, hit-count-bucket) pair (AFL bucketing, see ``HitCountBucket``), or — during screening — when it is boundary-derived and therefore carries empirical bug-finding value independent of its coverage. Duplicates are rejected by Zobrist hash before any coverage math runs.
///
/// ## Parent Selection
///
/// A weighted-random pick over the mutable tier. An entry's weight is `(rarity + α · noveltyBonus) · failureBoost`, where rarity is Σ 1/coveringEntryCount(edge) over the entry's edges, the novelty bonus is the same sum restricted to the edges the entry introduced, and the failure boost is the two-stage densification multiplier. Rarity is maintained incrementally: admission bumps per-edge covering counts and marks only the affected entries' cached scores dirty via the edge-to-entries index.
package final class SprawlCorpus {
    /// The edge capacity all signatures must share; fixed at init to the instrumented edge count.
    package let edgeCount: Int

    package private(set) var entries: [CorpusEntry] = []

    /// Indices of mutable-tier entries, the parent-selection domain.
    package private(set) var mutableTierIndices: [Int] = []

    /// Per-edge bitmask of hit-count buckets seen corpus-wide; novelty is a set bit not yet present.
    private var seenBucketMasks: [UInt8]

    /// Per-edge count of entries whose signature covers the edge; the rarity denominator.
    private var coveringEntryCounts: [Int]

    /// Edge → indices of entries covering it, for O(affected) score invalidation on admission.
    private var coveringEntries: [[Int]]

    /// Cached parent-selection scores, parallel to `entries`; nil means dirty.
    private var cachedScores: [Double?] = []

    private var seenHashes: Set<UInt64> = []

    /// Creates an empty corpus for a run with the given instrumented edge count.
    package init(edgeCount: Int) {
        self.edgeCount = edgeCount
        seenBucketMasks = Array(repeating: 0, count: edgeCount)
        coveringEntryCounts = Array(repeating: 0, count: edgeCount)
        coveringEntries = Array(repeating: [], count: edgeCount)
    }

    /// The number of edges any corpus entry has covered.
    package var coveredEdgeCount: Int {
        var total = 0
        for mask in seenBucketMasks where mask != 0 {
            total += 1
        }
        return total
    }

    // MARK: - Admission

    /// Offers a candidate to the corpus.
    ///
    /// - Parameters:
    ///   - sequence: The candidate's flattened choice sequence.
    ///   - tree: The choice tree behind `sequence`, kept as the mutation fallback.
    ///   - hits: The (edge, hit count) pairs from the candidate's attributed evaluation.
    ///   - convergence: The materialiser's convergence ratio; routes the entry to a tier.
    ///   - generation: Mutation distance from a phase-1/2 root.
    ///   - phase: The phase offering the candidate.
    ///   - isBoundaryDerived: Whether the candidate came from the covering array's boundary catalogues. Grants admission even without coverage novelty (phases 1 and 2 only; sprawl never sets this).
    /// - Returns: The admission verdict. On admission, seen-bucket masks and rarity counts are already updated.
    package func offer(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        hits: [(edge: Int, hitCount: UInt8)],
        convergence: Double,
        generation: Int,
        phase: SprawlPhase,
        isBoundaryDerived: Bool = false
    ) -> CorpusAdmission {
        let hash = ZobristHash.hash(of: sequence)
        guard seenHashes.contains(hash) == false else {
            return .rejectedDuplicate
        }

        var introducedEdges: [Int] = []
        var hasNovelBucket = false
        for (edge, hitCount) in hits {
            guard edge >= 0, edge < edgeCount else {
                continue
            }
            let mask = HitCountBucket.bucketMask(for: hitCount)
            if seenBucketMasks[edge] == 0 {
                introducedEdges.append(edge)
                hasNovelBucket = true
            } else if seenBucketMasks[edge] & mask == 0 {
                hasNovelBucket = true
            }
        }

        guard hasNovelBucket || isBoundaryDerived else {
            return .rejectedNotNovel
        }

        var signature = BitSet(capacity: edgeCount)
        for (edge, hitCount) in hits {
            guard edge >= 0, edge < edgeCount else {
                continue
            }
            signature.insert(edge)
            seenBucketMasks[edge] |= HitCountBucket.bucketMask(for: hitCount)
        }

        let index = entries.count
        let entry = CorpusEntry(
            sequence: sequence,
            tree: tree,
            signature: signature,
            convergence: convergence,
            generation: generation,
            phase: phase,
            hash: hash,
            introducedEdges: introducedEdges
        )
        entries.append(entry)
        cachedScores.append(nil)
        seenHashes.insert(hash)

        // Bump rarity denominators and dirty every entry whose score depends on a bumped edge.
        signature.forEachIndex { edge in
            coveringEntryCounts[edge] += 1
            for coveringIndex in coveringEntries[edge] {
                cachedScores[coveringIndex] = nil
            }
            coveringEntries[edge].append(index)
        }

        let tier: CorpusTier = convergence >= SprawlTunables.mutableTierConvergenceThreshold
            ? .mutable
            : .discovery
        if tier == .mutable {
            mutableTierIndices.append(index)
        }
        return .admitted(index: index, tier: tier)
    }

    // MARK: - Failure Weights

    /// Applies the immediate densification boost when a child of `parentIndex` fails, before reduction classifies the failure.
    package func applyProvisionalFailureBoost(toParentAt parentIndex: Int) {
        setFailureBoost(SprawlTunables.provisionalFailureBoost, at: parentIndex)
    }

    /// Replaces the provisional boost once the dispatched reduction has classified the failure.
    ///
    /// - Parameters:
    ///   - parentIndex: The parent whose child failed.
    ///   - isNewCluster: Whether the reduction created a new cluster.
    ///   - clusterInstanceCount: The cluster's instance count, which decays the existing-cluster boost.
    ///   - clusterCapReached: Whether the cluster's reduction cap is reached; a characterised fault stops contributing densification entirely.
    package func upgradeFailureBoost(
        atParentIndex parentIndex: Int,
        isNewCluster: Bool,
        clusterInstanceCount: Int,
        clusterCapReached: Bool
    ) {
        let boost: Double
        if isNewCluster {
            boost = SprawlTunables.newClusterFailureBoost
        } else if clusterCapReached {
            boost = 1.0
        } else {
            boost = 1.0 + (SprawlTunables.existingClusterFailureBoost - 1.0) / Double(max(1, clusterInstanceCount))
        }
        setFailureBoost(boost, at: parentIndex)
    }

    private func setFailureBoost(_ boost: Double, at index: Int) {
        guard entries.indices.contains(index) else {
            return
        }
        entries[index].failureBoost = boost
        cachedScores[index] = nil
    }

    // MARK: - Parent Selection

    /// The parent-selection score of the entry at `index`, computing and caching it if dirty.
    package func score(at index: Int) -> Double {
        if let cached = cachedScores[index] {
            return cached
        }
        let entry = entries[index]
        var rarity = 0.0
        entry.signature.forEachIndex { edge in
            rarity += 1.0 / Double(coveringEntryCounts[edge])
        }
        var noveltyBonus = 0.0
        for edge in entry.introducedEdges {
            noveltyBonus += 1.0 / Double(coveringEntryCounts[edge])
        }
        let score = (rarity + SprawlTunables.noveltyBonusWeight * noveltyBonus) * entry.failureBoost
        cachedScores[index] = score
        return score
    }

    /// Picks a mutation parent by weighted random draw over the mutable tier, or nil when the tier is empty.
    ///
    /// - Parameter random: A uniform draw in [0, 1), supplied by the caller so runs stay deterministic under a pinned seed.
    package func pickParent(random: Double) -> (index: Int, entry: CorpusEntry)? {
        guard mutableTierIndices.isEmpty == false else {
            return nil
        }
        var totalWeight = 0.0
        for index in mutableTierIndices {
            totalWeight += score(at: index)
        }
        guard totalWeight > 0 else {
            let fallbackIndex = mutableTierIndices[min(
                Int(random * Double(mutableTierIndices.count)),
                mutableTierIndices.count - 1
            )]
            return (fallbackIndex, entries[fallbackIndex])
        }
        var remaining = random * totalWeight
        for index in mutableTierIndices {
            remaining -= score(at: index)
            if remaining < 0 {
                return (index, entries[index])
            }
        }
        let lastIndex = mutableTierIndices[mutableTierIndices.count - 1]
        return (lastIndex, entries[lastIndex])
    }
}
