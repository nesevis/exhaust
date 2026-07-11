// The corpus of coverage-interesting inputs driving parent selection during sprawl.

/// One accepted input: its choice sequence, coverage signature, and parent-selection state.
package struct CorpusEntry: Sendable {
    /// The flattened choice sequence — the mutation substrate.
    package let sequence: ChoiceSequence

    /// The choice tree behind `sequence`, kept as the guided-materialisation fallback for mutations of this entry.
    package let tree: ChoiceTree

    /// The edges hit during this entry's property evaluation.
    package let signature: BitSet

    /// The raw (edge, saturating count) pairs behind `signature`, retained so a progress-log restore can re-offer the entry with its original bucket information.
    package let hits: [(edge: Int, hitCount: UInt8)]

    /// Whether the entry was admitted on boundary-derived credit rather than coverage novelty. Retained for faithful re-offer on restore.
    package let isBoundaryDerived: Bool

    /// The materialiser's convergence ratio for this entry; decides tier membership.
    package let convergence: Double

    /// Mutation distance from a phase-1/2 root: roots are 0, a mutation of a parent is `parent.generation + 1`.
    package let generation: Int

    /// The phase that produced this entry.
    package let phase: SprawlPhase

    /// Whether the property failed on this entry. Report-time discrimination splits the corpus on this flag: passing entries form the P(hit | pass) denominator.
    package let propertyFailed: Bool

    /// Zobrist hash of `sequence`, the corpus-wide dedup key.
    package let hash: UInt64

    /// The edges this entry was first to cover, corpus-wide. The novelty bonus is rarity over these edges, so it decays automatically as other entries accumulate hits on them.
    let introducedEdges: [Int]

    /// Multiplier on the entry's parent-selection score from failures among its children. 1 when no child failed; see ``SprawlTunables`` for the provisional and cluster-aware values.
    var failureBoost: Double = 1.0

    // MARK: - Power-Schedule State (Experiment: powerSchedule)

    /// Times this entry has been picked as a mutation parent.
    var timesPicked: Int = 0

    /// Children spawned from this entry across all picks — the frequency denominator in the energy formula.
    var childrenSpawned: Int = 0
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

    /// Per-edge attempt-incidence counters saturating at 3, updated inside the offer walk the loop already pays for. Only the singleton and doubleton counts feed the STADS estimators. Duplicate-sequence offers return before the walk and are not counted — a duplicate re-hits an already-counted edge set, and the resulting bias overstates remaining discovery, the conservative direction for a completeness estimate.
    private var edgeIncidenceCounts: [UInt8]

    /// Edge → indices of entries covering it, for O(affected) score invalidation on admission.
    private var coveringEntries: [[Int]]

    /// Cached parent-selection scores, parallel to `entries`; nil means dirty.
    private var cachedScores: [Double?] = []

    private var seenHashes: Set<UInt64> = []

    /// Experiment knobs; the corpus reads `championArchive`.
    private let experiments: SprawlExperiments

    // MARK: - Champion Archive (Experiment: championArchive)

    // A quality-diversity archive in the MAP-Elites frame: each covered edge is a behavior cell holding the shortlex-minimal mutable-tier entry that hits it, and the parent-selection domain is the entries holding at least one cell. Smaller parents mutate faster and carry less incidental coverage; subsumption pruning was rejected because it is order-dependent and lets one large entry shadow rare-edge champions. Championships are scoped to mutable-tier-eligible entries — a discovery-tier entry keeps its coverage credit but must not be able to empty the mutation pool by holding cells it can never be mutated from.

    /// The entry index holding each edge's cell, or nil while the edge is uncovered (or its champion was quarantined).
    private var edgeChampions: [Int?]

    /// Cells held per entry, parallel to `entries`; an entry leaves parent selection when its count returns to zero.
    private var championCounts: [Int] = []

    /// Creates an empty corpus for a run with the given instrumented edge count.
    package init(edgeCount: Int, experiments: SprawlExperiments = SprawlExperiments()) {
        self.edgeCount = edgeCount
        self.experiments = experiments
        seenBucketMasks = Array(repeating: 0, count: edgeCount)
        coveringEntryCounts = Array(repeating: 0, count: edgeCount)
        coveringEntries = Array(repeating: [], count: edgeCount)
        edgeChampions = Array(repeating: nil, count: edgeCount)
        edgeIncidenceCounts = Array(repeating: 0, count: edgeCount)
    }

    /// Signatures of entries whose property evaluation passed — the P(hit | pass) sample for report-time discrimination.
    package var passingSignatures: [BitSet] {
        entries.filter { $0.propertyFailed == false }.map(\.signature)
    }

    /// Edges hit by exactly one non-duplicate attempt (f₁), for the STADS estimators.
    package var edgeSingletonCount: Int {
        edgeIncidenceCounts.count(where: { $0 == 1 })
    }

    /// Edges hit by exactly two non-duplicate attempts (f₂), for the STADS estimators.
    package var edgeDoubletonCount: Int {
        edgeIncidenceCounts.count(where: { $0 == 2 })
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
    ///   - propertyFailed: Whether the property failed on this candidate, recorded for report-time discrimination.
    /// - Returns: The admission verdict. On admission, seen-bucket masks and rarity counts are already updated.
    package func offer(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        hits: [(edge: Int, hitCount: UInt8)],
        convergence: Double,
        generation: Int,
        phase: SprawlPhase,
        isBoundaryDerived: Bool = false,
        propertyFailed: Bool = false
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
            if edgeIncidenceCounts[edge] < 3 {
                edgeIncidenceCounts[edge] += 1
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
            hits: hits,
            isBoundaryDerived: isBoundaryDerived,
            convergence: convergence,
            generation: generation,
            phase: phase,
            propertyFailed: propertyFailed,
            hash: hash,
            introducedEdges: introducedEdges
        )
        entries.append(entry)
        cachedScores.append(nil)
        championCounts.append(0)
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
        if tier == .mutable, quarantinedHashes.contains(hash) == false {
            if experiments.championArchive {
                claimChampionships(for: index, signature: signature)
                if championCounts[index] > 0 {
                    mutableTierIndices.append(index)
                }
            } else {
                mutableTierIndices.append(index)
            }
        }
        return .admitted(index: index, tier: tier)
    }

    // MARK: - Champion Archive

    /// Claims every cell of `signature` the new entry wins by shortlex comparison, evicting dethroned entries whose cell count returns to zero from parent selection.
    ///
    /// One comparison per hit edge on admission; admissions are rare, so this never touches the per-attempt path. Eviction is deterministic: only championship arithmetic removes an entry, never insertion order.
    private func claimChampionships(for index: Int, signature: BitSet) {
        let sequence = entries[index].sequence
        signature.forEachIndex { edge in
            guard let incumbentIndex = edgeChampions[edge] else {
                edgeChampions[edge] = index
                championCounts[index] += 1
                return
            }
            guard shortlexIsLess(sequence, entries[incumbentIndex].sequence) else {
                return
            }
            edgeChampions[edge] = index
            championCounts[index] += 1
            championCounts[incumbentIndex] -= 1
            if championCounts[incumbentIndex] == 0 {
                mutableTierIndices.removeAll { $0 == incumbentIndex }
            }
        }
    }

    /// Shortlex order over flattened sequences: shorter first, ties broken by the first differing element (kind rank, then per-kind payload). Reflexive ties are not-less, so an incumbent keeps its cell against an equal challenger.
    private func shortlexIsLess(_ lhs: ChoiceSequence, _ rhs: ChoiceSequence) -> Bool {
        if lhs.count != rhs.count {
            return lhs.count < rhs.count
        }
        for (left, right) in zip(lhs, rhs) {
            let leftRank = elementRank(left)
            let rightRank = elementRank(right)
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            if case let .value(leftValue) = left, case let .value(rightValue) = right,
               leftValue.choice.bitPattern64 != rightValue.choice.bitPattern64
            {
                return leftValue.choice.bitPattern64 < rightValue.choice.bitPattern64
            }
            if case let .branch(leftBranch) = left, case let .branch(rightBranch) = right,
               leftBranch.id != rightBranch.id
            {
                return leftBranch.id < rightBranch.id
            }
        }
        return false
    }

    /// A stable rank per element kind, so structurally different same-length sequences still order totally.
    private func elementRank(_ element: ChoiceSequenceValue) -> Int {
        switch element {
            case .just:
                0
            case .value:
                1
            case .branch:
                2
            case .group(true):
                3
            case .group(false):
                4
            case .sequence(true, _, _):
                5
            case .sequence(false, _, _):
                6
            case .bind(true):
                7
            case .bind(false):
                8
        }
    }

    // MARK: - Quarantine

    /// Removes the entry with the given sequence hash from parent selection. A run resumed after a trap quarantines the crash region — densification would otherwise steer sprawl straight back into the trap, crash-looping the suite.
    ///
    /// The entry keeps its coverage credit and rarity contributions; only its eligibility as a mutation root is revoked. A hash with no corpus entry (the trapping candidate itself, which died before admission) is remembered so a later identical admission is barred too.
    package func quarantine(sequenceHash: UInt64) {
        quarantinedHashes.insert(sequenceHash)
        mutableTierIndices.removeAll { entries[$0].hash == sequenceHash }
        guard experiments.championArchive else {
            return
        }
        // A quarantined champion releases its cells rather than locking them to an entry that can never be mutated again; later admissions may reclaim them. Championship arithmetic can never re-admit the entry — offer checks the quarantine set before any claiming happens.
        for index in entries.indices where entries[index].hash == sequenceHash {
            guard championCounts[index] > 0 else {
                continue
            }
            for edge in edgeChampions.indices where edgeChampions[edge] == index {
                edgeChampions[edge] = nil
            }
            championCounts[index] = 0
        }
    }

    private var quarantinedHashes: Set<UInt64> = []

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

    // MARK: - Power Schedule

    /// The number of children to draw from the parent at `index` under the AFLFast-family FAST schedule, mutating the entry's pick counters.
    ///
    /// The formula is `base · 2^s / (1 + f)` clamped to `1 ... cap`, where `s` counts prior picks (bounded by ``SprawlTunables/powerScheduleExponentLimit``) and `f` counts children already spawned. AFLFast's `f` is path frequency — how many generated inputs exercised the seed's path — which the corpus does not track per attempt; children spawned is the cheap proxy with the same intent: a neighborhood that has already been fuzzed heavily earns less energy per visit, while a parent the schedule keeps returning to (rare coverage keeps it winning selection) ramps up exponentially until the cap.
    package func powerScheduleChildren(forParentAt index: Int, base: Int) -> Int {
        entries[index].timesPicked += 1
        let exponent = min(entries[index].timesPicked - 1, SprawlTunables.powerScheduleExponentLimit)
        let frequency = 1 + entries[index].childrenSpawned
        let energy = base * (1 << exponent) / frequency
        let clamped = min(max(energy, 1), SprawlTunables.powerScheduleEnergyCap)
        entries[index].childrenSpawned += clamped
        return clamped
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
