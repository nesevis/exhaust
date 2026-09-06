// The corpus of coverage-interesting inputs driving parent selection during fuzzing.

/// One accepted input: its choice sequence, coverage signature, and parent-selection state.
package struct CorpusEntry: Sendable {
    /// The flattened choice sequence — the mutation substrate.
    package let sequence: ChoiceSequence

    /// Stable leaf, branch, and bind positions reused across this entry's children. Nil for discovery-tier entries, which are never mutation parents.
    package let mutationLayout: FuzzMutator.Layout?

    /// The choice tree behind `sequence`, kept as the guided-materialization fallback for mutations of this entry.
    ///
    /// `ChoiceSequence.flatten(tree)` equals `sequence` for every admitted entry: the admission paths either construct `sequence` that way or assert the equality before offering. Read `sequence` rather than re-flattening.
    package let tree: ChoiceTree

    /// The graph and scope caches the graph-targeted mutation operators resolve their positions through.
    ///
    /// Nil until something needs them: construction walks the whole graph, so it is deferred to the first parent draw that consumes it. Stays nil forever for discovery-tier entries, which are never mutation parents, and for runs whose experiment knobs consume no targeting tables. Read it through ``FuzzCorpus/mutationTargets(forParentAt:)``, which fills it on demand — a direct read sees nil for an entry that has not been drawn yet.
    package fileprivate(set) var mutationTargets: MutationTargets?

    /// The (edge, saturating count) pairs from this entry's property evaluation, in first-hit order, filtered to the corpus edge domain at admission.
    ///
    /// The only record of what the entry covered. A `BitSet` over the whole edge domain costs 11 KB per entry on a 90k-edge build whatever share of it is set, so the pairs carry the coverage and report-time discrimination builds its bitmaps from them. Consumers walk this directly and need no bounds check.
    package let hits: [(edge: Int, hitCount: UInt8)]

    /// Whether the entry's evaluation hit `edge`.
    ///
    /// - Complexity: O(*n*) in the entry's covered edges. Membership is not what the search asks of an entry, which walks every edge; use it for a single query, not inside a loop over the domain.
    package func covers(_ edge: Int) -> Bool {
        hits.contains { $0.edge == edge }
    }

    /// Whether the entry was admitted on boundary-derived credit rather than coverage novelty. Retained for faithful re-offer on restore.
    package let isBoundaryDerived: Bool

    /// The materializer's convergence ratio for this entry: the share of coordinates resolved from the mutated prefix or the fallback tree rather than the PRNG. Decides tier membership at admission; retained afterwards only for the checkpoint record.
    package let convergence: Double

    /// Mutation distance from a phase-1/2 root: roots are 0, a mutation of a parent is `parent.generation + 1`.
    package let generation: Int

    /// The phase that produced this entry.
    package let phase: FuzzPhase

    /// Whether the property failed on this entry. Report-time discrimination splits the corpus on this flag: passing entries form the P(hit | pass) denominator.
    package let propertyFailed: Bool

    /// Whether the property discarded this entry (its precondition was not met). Admitted on coverage novelty like any other entry, but weighted down as a mutation parent and excluded from the passing sample.
    package let propertyDiscarded: Bool

    /// Zobrist hash of `sequence`, the corpus-wide dedup key.
    package let hash: UInt64

    /// The edges this entry was first to cover, corpus-wide. The novelty bonus is rarity over these edges, so it decays automatically as other entries accumulate hits on them.
    ///
    /// Derived from the admission masks, which ``FuzzCorpus/resetNoveltyBaseline()`` clears at the screening handover, so an edge screening already reached can appear here again. That is deliberate for the search signal and wrong for a discovery clock; ``coveredRunFirstEdge`` is the clock's input.
    let introducedEdges: [Int]

    /// Whether this entry reached an edge no attempt in the run had covered before, from the cumulative record rather than the admission masks. Unlike `introducedEdges` this survives the novelty-baseline reset, so rediscovery after the screening handover does not restart the run's time-to-last-discovery.
    let coveredRunFirstEdge: Bool

    /// Multiplier on the entry's parent-selection score from failures among its children. 1 when no child failed; see ``FuzzTunables`` for the provisional and cluster-aware values.
    var failureBoost: Double = 1.0
}

/// Which tier an admitted entry landed in.
///
/// The split is a length guard for the champion archive. Convergence says nothing about an entry's worth as a parent: the stored sequence is the materializer's complete output whatever share of it the PRNG supplied. What it does track is length. A child that fell through to the PRNG is short, the archive orders champions by shortlex, and a short entry claims many cells at once and evicts the longer incumbents holding them. Admitting every entry as a parent was measured on IFC (`fuzz-loop-experiments-2026-09-06.md`): the parent pool shrank 4.5%, its mean length fell 4.1%, and covered edges fell 3.1% while the corpus stayed flat. The tier keeps those entries' coverage credit and denies them cells.
package enum CorpusTier: Sendable, Equatable {
    /// Eligible for parent selection and for champion cells.
    case mutable
    /// Retained for coverage credit and rarity counts, but never a mutation parent and never a champion. Such entries are short, and letting them claim cells sweeps longer incumbents out of the archive; see ``FuzzTunables/mutableTierConvergenceThreshold``.
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
    /// The evaluation reached no verdict, so the candidate was never offered. Its coverage describes a stalled execution rather than the input.
    case rejectedInconclusive

    /// Whether the candidate was accepted, in either tier. Admission is the loop's coverage-novelty signal: it resets plateau windows and marks failures as coverage-novel for the reduction gate.
    package var isAdmitted: Bool {
        if case .admitted = self {
            return true
        }
        return false
    }
}

/// The edge tallies the STADS estimators consume, counted together.
package struct EdgeIncidenceProfile: Sendable {
    /// Edges any corpus entry has covered.
    package let covered: Int
    /// Edges hit by exactly one non-duplicate attempt (Q1).
    package let singletons: Int
    /// Edges hit by exactly two non-duplicate attempts (Q2).
    package let doubletons: Int
    /// Edges hit by exactly three non-duplicate attempts (Q3).
    package let tripletons: Int
    /// Edges hit by exactly four non-duplicate attempts (Q4).
    package let quadrupletons: Int
}

/// The shape of the parent domain at one moment: how long its sequences are, and how many champion cells each parent holds.
///
/// Exists because parent count alone cannot tell displacement from growth. A short entry that claims many cells evicts several longer incumbents at once, so the domain can shrink while admissions rise; the length figures against ``meanEntryLength`` show whether the parents are a shorter population than the corpus they were drawn from, and the cell figures show whether a few entries hold most of the archive.
package struct ParentProfile: Sendable, Equatable {
    /// Entries in the parent domain.
    package let parentCount: Int
    /// Sequence lengths over the parent domain.
    package let minimumLength: Int
    package let medianLength: Int
    package let meanLength: Double
    package let maximumLength: Int
    /// Mean sequence length over every admitted entry, parent or not, as the comparison point for the parent figures.
    package let meanEntryLength: Double
    /// Champion cells held per parent. All zero when the archive is off.
    package let minimumCells: Int
    package let medianCells: Int
    package let meanCells: Double
    package let maximumCells: Int

    package static let empty = ParentProfile(
        parentCount: 0,
        minimumLength: 0,
        medianLength: 0,
        meanLength: 0,
        maximumLength: 0,
        meanEntryLength: 0,
        minimumCells: 0,
        medianCells: 0,
        meanCells: 0,
        maximumCells: 0
    )

    package init(
        parentCount: Int,
        minimumLength: Int,
        medianLength: Int,
        meanLength: Double,
        maximumLength: Int,
        meanEntryLength: Double,
        minimumCells: Int,
        medianCells: Int,
        meanCells: Double,
        maximumCells: Int
    ) {
        self.parentCount = parentCount
        self.minimumLength = minimumLength
        self.medianLength = medianLength
        self.meanLength = meanLength
        self.maximumLength = maximumLength
        self.meanEntryLength = meanEntryLength
        self.minimumCells = minimumCells
        self.medianCells = medianCells
        self.meanCells = meanCells
        self.maximumCells = maximumCells
    }
}

/// Accumulates coverage-interesting inputs and answers "which parent should the mutation phase mutate next?"
///
/// Single-threaded by design: the exploration loop owns the corpus and touches it between attempts, so no synchronisation is needed on the hot path. Failure-weight updates arriving from completed reduction Tasks must be routed through the owning loop rather than calling in from another thread.
///
/// ## Acceptance
///
/// A candidate enters when its signature contains a new edge or a new (edge, hit-count-bucket) pair (AFL bucketing, see ``HitCountBucket``), or — during screening — when it is boundary-derived and therefore carries empirical bug-finding value independent of its coverage. Duplicates are rejected by Zobrist hash before any coverage math runs.
///
/// ## Parent Selection
///
/// A weighted-random pick over the parent domain: mutable-tier entries that are not quarantined and, with the champion archive on, hold at least one cell. The tier exists to keep short low-convergence entries out of the archive (see ``CorpusTier``). An entry's weight is `(rarity + α · noveltyBonus) · failureBoost`, where rarity is Σ 1/coveringEntryCount(edge) over the entry's edges, the novelty bonus is the same sum restricted to the edges the entry introduced, and the failure boost is the two-stage densification multiplier. Rarity is maintained incrementally: admission bumps per-edge covering counts and marks only the affected entries' cached scores dirty via the edge-to-entries index.
package final class FuzzCorpus {
    /// The edge capacity all signatures must share; fixed at init to the instrumented edge count.
    package let edgeCount: Int

    package private(set) var entries: [CorpusEntry] = []

    /// Indices of the mutable-tier entries eligible as mutation parents: not quarantined and, with the champion archive on, holding at least one cell.
    package private(set) var parentIndices: [Int] = []

    /// Per-edge bitmask of hit-count buckets seen corpus-wide; novelty is a set bit not yet present.
    private var seenBucketMasks: [UInt8]
    /// Cumulative record of every edge an admitted entry has covered, kept apart from the admission masks so ``coveredEdgeCount`` keeps reporting the whole run after ``resetNoveltyBaseline()``.
    private var everCoveredEdges: [Bool]

    /// Per-edge count of entries whose signature covers the edge; the rarity denominator.
    private var coveringEntryCounts: [Int]

    /// Per-edge attempt-incidence counters saturating at 5, updated inside the offer walk the loop already pays for. Singletons and doubletons feed Chao2; tripletons and quadrupletons feed iChao2, which is why the cap is 5 rather than 3. Duplicate-sequence offers return before the walk and are not counted — a duplicate re-hits an already-counted edge set, and the resulting bias overstates remaining discovery, the conservative direction for a completeness estimate.
    private var edgeIncidenceCounts: [UInt8]

    /// Sum of all entries in the incidence matrix (`V = Σₖ k·Qₖ`): every (attempt, edge) pair counted once.
    ///
    /// The denominator of the Bernoulli-product discovery probability. One input covers many edges, so the number of attempts is the wrong denominator for incidence data; `V` is the right one and aggregates online without ever materializing the matrix.
    private var incidenceTotalCount: Int = 0

    /// Counts incidence-matrix rows. A conclusive, nonduplicate offer contributes one row even when it hits no edge; inconclusive attempts never reach ``offer`` and duplicate sequences return before the row is counted.
    private var incidenceSampleCountStorage: Int = 0

    /// Edge → indices of parent-eligible entries covering it, for O(affected) score invalidation on admission. Entries that can never be picked as parents are not indexed, because their cached score is never read.
    private var coveringEntries: [[Int]]

    /// Cached parent-selection scores, parallel to `entries`; nil means dirty.
    private var cachedScores: [Double?] = []

    /// Running sums of the mutable tier's scores in tier order, so a pick is one binary search instead of two passes over the tier. Rebuilt lazily on the first pick after anything that can move a score or the tier: an admission, a failure boost, a champion eviction, or a quarantine.
    private var tierPrefixSums: [Double] = []
    private var tierPrefixSumsValid = false

    private var seenHashes: Set<UInt64> = []

    /// Hashes of recently evaluated sequences, so a candidate the property has already judged is skipped before it runs again.
    private var recentHashes = RecentHashTable(capacityExponent: 16)

    /// Records that a candidate with this hash is about to reach the property, and reports whether one already did within the recent window.
    package func markEvaluated(hash: UInt64) -> Bool {
        recentHashes.insertReportingPresence(hash)
    }

    /// Experiment knobs; the corpus reads the targeting knobs to decide whether entries build mutation tables.
    private let experiments: FuzzExperiments

    // MARK: - Champion Archive

    // A quality-diversity archive in the MAP-Elites frame: each covered edge is a behavior cell holding the shortlex-minimal mutable-tier entry that hits it, and the parent-selection domain is the entries holding at least one cell. Smaller parents mutate faster and carry less incidental coverage; subsumption pruning was rejected because it is order-dependent and lets one large entry shadow rare-edge champions. Championships are scoped to mutable-tier entries. A discovery-tier entry keeps its coverage credit but claims no cells: such entries are short, shortlex favours them, and letting them claim cells evicted the longer incumbents and cost IFC 3.1% of covered edges when measured (see ``CorpusTier``). The archive itself is net-beneficial; the same measurement found that turning it off costs a further 1.9% coverage and 37% throughput, because parents drawn from the whole corpus are 3.5 times longer.

    /// The entry index holding each edge's cell, or nil while the edge is uncovered (or its champion was quarantined).
    private var edgeChampions: [Int?]

    /// Cells held per entry, parallel to `entries`; an entry leaves parent selection when its count returns to zero.
    private var championCounts: [Int] = []

    /// Creates an empty corpus for a run with the given instrumented edge count.
    package init(edgeCount: Int, experiments: FuzzExperiments = FuzzExperiments()) {
        self.edgeCount = edgeCount
        self.experiments = experiments
        seenBucketMasks = Array(repeating: 0, count: edgeCount)
        everCoveredEdges = Array(repeating: false, count: edgeCount)
        coveringEntryCounts = Array(repeating: 0, count: edgeCount)
        coveringEntries = Array(repeating: [], count: edgeCount)
        edgeChampions = Array(repeating: nil, count: edgeCount)
        edgeIncidenceCounts = Array(repeating: 0, count: edgeCount)
    }

    /// The number of (edge, entry) pairs the invalidation index holds. Package-visible so a test can pin that the index tracks parent-eligible entries rather than the whole corpus: on a low-edge target with many boundary-credit admissions, indexing every entry made admission quadratic.
    package var invalidationIndexSize: Int {
        coveringEntries.reduce(0) { $0 + $1.count }
    }

    /// The passing entries as per-edge hit counts: the P(hit | pass) sample for report-time discrimination. Discarded entries are neither passing nor failing and stay out of the sample.
    package var passingSample: PassingSample {
        PassingSample(
            passingHits: entries.lazy
                .filter { $0.propertyFailed == false && $0.propertyDiscarded == false }
                .map(\.hits),
            edgeCount: edgeCount
        )
    }

    /// The covered-edge tally and the Q1 through Q4 incidence classes, from one pass over the edge domain.
    ///
    /// One pass rather than one per tally: the saturation check reads all five on every plateau probe, and at the instrumented edge counts a real build carries, five walks of the domain is five times the work for one answer.
    package var edgeIncidenceProfile: EdgeIncidenceProfile {
        var covered = 0
        var singletons = 0
        var doubletons = 0
        var tripletons = 0
        var quadrupletons = 0
        for edge in 0 ..< edgeCount {
            if everCoveredEdges[edge] {
                covered += 1
            }
            switch edgeIncidenceCounts[edge] {
                case 1:
                    singletons += 1
                case 2:
                    doubletons += 1
                case 3:
                    tripletons += 1
                case 4:
                    quadrupletons += 1
                default:
                    break
            }
        }
        return EdgeIncidenceProfile(
            covered: covered,
            singletons: singletons,
            doubletons: doubletons,
            tripletons: tripletons,
            quadrupletons: quadrupletons
        )
    }

    /// The parent domain's length and cell distribution. Sorts the domain, so it is read once at report time, never per attempt.
    package var parentProfile: ParentProfile {
        guard parentIndices.isEmpty == false else {
            return .empty
        }
        let lengths = parentIndices.map { entries[$0].sequence.count }.sorted()
        let cells = parentIndices.map { championCounts[$0] }.sorted()
        let entryLengthTotal = entries.reduce(0) { $0 + $1.sequence.count }
        return ParentProfile(
            parentCount: parentIndices.count,
            minimumLength: lengths[0],
            medianLength: lengths[lengths.count / 2],
            meanLength: Double(lengths.reduce(0, +)) / Double(lengths.count),
            maximumLength: lengths[lengths.count - 1],
            meanEntryLength: Double(entryLengthTotal) / Double(entries.count),
            minimumCells: cells[0],
            medianCells: cells[cells.count / 2],
            meanCells: Double(cells.reduce(0, +)) / Double(cells.count),
            maximumCells: cells[cells.count - 1]
        )
    }

    /// Sum of all entries in the incidence matrix (`V`), the discovery-probability denominator.
    package var incidenceTotal: Int {
        incidenceTotalCount
    }

    package var incidenceSampleCount: Int {
        incidenceSampleCountStorage
    }

    /// The number of edges any corpus entry has covered. Cumulative across the whole run: a novelty reset clears the admission masks, not this tally.
    package var coveredEdgeCount: Int {
        var total = 0
        for covered in everCoveredEdges where covered {
            total += 1
        }
        return total
    }

    // MARK: - Admission

    /// Zeroes the per-edge incidence counts and their total, without touching entries, coverage, or admission masks.
    ///
    /// Called once at the end of a crash restore. Restoring re-offers every persisted entry, and each re-offer bumps these counts, so a resumed run would otherwise begin with incidence from re-offers that were never attempts of this run. The STADS estimators read these counts, so the saturation stop and the reported chance that the next attempt covers a new edge would both describe a mixture of two runs. Zeroing makes them describe post-resume attempts, which is what the report already tells the reader on a resumed run.
    package func resetIncidenceStatistics() {
        for index in edgeIncidenceCounts.indices {
            edgeIncidenceCounts[index] = 0
        }
        incidenceTotalCount = 0
        incidenceSampleCountStorage = 0
    }

    /// Clears the admission-novelty baseline while keeping every entry, statistic, and report tally.
    ///
    /// Called once at the screening-to-sampling handover. Screening's covering array rows are an analysis pass, and letting their coverage bind search admission can spend the entire novelty gradient before search begins: on a sparse precondition the boundary rows light most of the map, no search-phase candidate is ever coverage-novel, and the run plateaus having admitted nothing, which is the corpus-capture failure mode. After the reset the search phases start with the fresh map a screening-free run has, while screening's admitted entries keep competing as mutation parents and ``coveredEdgeCount`` keeps reporting the whole run.
    package func resetNoveltyBaseline() {
        for index in seenBucketMasks.indices {
            seenBucketMasks[index] = 0
        }
    }

    /// Whether the (edge, hit count) pair lands in a bucket no admitted entry has produced for that edge. The single admission-novelty predicate: ``offer(sequence:tree:hits:convergence:generation:phase:isBoundaryDerived:propertyFailed:)`` and ``wouldAdmit(hits:)`` both build on it, so the pre-check cannot drift from real admission. An unseen edge has mask 0 and is therefore always novel.
    private func isNovelBucket(edge: Int, hitCount: UInt8) -> Bool {
        seenBucketMasks[edge] & HitCountBucket.bucketMask(for: hitCount) == 0
    }

    /// Answers whether a candidate with the given hits would be admitted without mutating corpus state.
    ///
    /// The spec path's prune hook uses this to decide whether pruning is worth running on a passing candidate: pruning costs one sequential SUT execution, so the hook fires only on failures and would-be admissions.
    package func wouldAdmit(hits: [(edge: Int, hitCount: UInt8)]) -> Bool {
        hits.contains { edge, hitCount in
            edge >= 0 && edge < edgeCount && isNovelBucket(edge: edge, hitCount: hitCount)
        }
    }

    /// Offers a candidate to the corpus.
    ///
    /// - Parameters:
    ///   - sequence: The candidate's flattened choice sequence.
    ///   - tree: The choice tree behind `sequence`, kept as the mutation fallback.
    ///   - hits: The (edge, hit count) pairs from the candidate's attributed evaluation.
    ///   - convergence: The materializer's convergence ratio; routes the entry to a tier.
    ///   - generation: Mutation distance from a phase-1/2 root.
    ///   - phase: The phase offering the candidate.
    ///   - isBoundaryDerived: Whether the candidate came from the covering array's boundary catalogs. Grants admission even without coverage novelty (phases 1 and 2 only; the mutation phase never sets this).
    ///   - propertyFailed: Whether the property failed on this candidate, recorded for report-time discrimination.
    ///   - precomputedHash: `ZobristHash.hash(of:)` of `sequence` when the caller already computed it (the runner hashes every fresh sequence for the crash breadcrumb); must match exactly. Nil recomputes here.
    /// - Returns: The admission verdict. On admission, seen-bucket masks and rarity counts are already updated.
    /// Whether the entry admitted at this index brought edges nothing had reached before.
    ///
    /// Admission alone does not imply new code: a candidate also enters on a new (edge, hit-count
    /// bucket) pair, which is the right criterion for keeping a mutation parent and the wrong one for
    /// deciding a run has stopped discovering.
    package func introducedNewEdges(at index: Int) -> Bool {
        guard index >= 0, index < entries.count else {
            return false
        }
        return entries[index].introducedEdges.isEmpty == false
    }

    /// Whether the entry admitted at this index reached an edge no attempt had covered before.
    ///
    /// ``introducedNewEdges(at:)`` answers the same question against the admission masks, which ``resetNoveltyBaseline()`` clears, so after the screening handover it counts rediscovery as discovery. Use this one for anything that reports or decides on how long the run has gone without finding new code.
    package func coveredRunFirstEdge(at index: Int) -> Bool {
        guard index >= 0, index < entries.count else {
            return false
        }
        return entries[index].coveredRunFirstEdge
    }

    package func offer(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        hits: [(edge: Int, hitCount: UInt8)],
        convergence: Double,
        generation: Int,
        phase: FuzzPhase,
        isBoundaryDerived: Bool = false,
        propertyFailed: Bool = false,
        propertyDiscarded: Bool = false,
        precomputedHash: UInt64? = nil
    ) -> CorpusAdmission {
        let hash = precomputedHash ?? ZobristHash.hash(of: sequence)
        guard seenHashes.contains(hash) == false else {
            return .rejectedDuplicate
        }
        incidenceSampleCountStorage += 1

        var introducedEdges: [Int] = []
        var hasNovelBucket = false
        for (edge, hitCount) in hits {
            guard edge >= 0, edge < edgeCount else {
                continue
            }
            incidenceTotalCount += 1
            if edgeIncidenceCounts[edge] < 5 {
                edgeIncidenceCounts[edge] += 1
            }
            if seenBucketMasks[edge] == 0 {
                introducedEdges.append(edge)
            }
            if isNovelBucket(edge: edge, hitCount: hitCount) {
                hasNovelBucket = true
            }
        }

        guard hasNovelBucket || isBoundaryDerived else {
            return .rejectedNotNovel
        }

        // Filtering once here is what lets every later consumer walk the pairs without repeating the domain check.
        var storedHits: [(edge: Int, hitCount: UInt8)] = []
        storedHits.reserveCapacity(hits.count)
        var coveredRunFirstEdge = false
        for (edge, hitCount) in hits {
            guard edge >= 0, edge < edgeCount else {
                continue
            }
            storedHits.append((edge, hitCount))
            seenBucketMasks[edge] |= HitCountBucket.bucketMask(for: hitCount)
            if everCoveredEdges[edge] == false {
                coveredRunFirstEdge = true
                everCoveredEdges[edge] = true
            }
        }

        let tier: CorpusTier = convergence >= FuzzTunables.mutableTierConvergenceThreshold
            ? .mutable
            : .discovery
        let index = entries.count

        let entry = CorpusEntry(
            sequence: sequence,
            // Only mutable-tier entries become mutation parents, so only they pay for and retain the layout index.
            mutationLayout: tier == .mutable ? FuzzMutator.layout(of: sequence, tree: tree) : nil,
            tree: tree,
            // Deferred to the first parent draw that consumes it; see `mutationTargets(forParentAt:)`.
            mutationTargets: nil,
            hits: storedHits,
            isBoundaryDerived: isBoundaryDerived,
            convergence: convergence,
            generation: generation,
            phase: phase,
            propertyFailed: propertyFailed,
            propertyDiscarded: propertyDiscarded,
            hash: hash,
            introducedEdges: introducedEdges,
            coveredRunFirstEdge: coveredRunFirstEdge
        )
        entries.append(entry)
        cachedScores.append(nil)
        championCounts.append(0)
        donorFingerprints.append([])
        seenHashes.insert(hash)

        var isParentEligible = false
        if tier == .mutable, quarantinedHashes.contains(hash) == false {
            claimChampionships(for: index)
            if championCounts[index] > 0 {
                parentIndices.append(index)
                isParentEligible = true
            }
        }
        // Typed crossover is the one consumer that cannot wait for this entry's own first parent draw: its donor pool is corpus-wide, read by every *other* entry's crossover, so an entry that has not yet been mutated must already be donatable. That forces the graph build eagerly under `pairMutation` — the other targeting consumers defer.
        if isParentEligible, experiments.pairMutation {
            let targets = MutationTargets(tree: tree)
            entries[index].mutationTargets = targets
            registerDonorSpans(forEntryAt: index, graph: targets.graph)
        }

        // Bump rarity denominators and dirty every entry whose score depends on a bumped edge. Only parent-eligible entries ever have their score read, so only they are indexed for invalidation. Indexing every entry made admission cost O(corpus) per edge, and boundary-credit screening rows on a low-edge target turn that into a quadratic stall: 1.5 ms per row at -Onone on a 12-edge fixture, with the run never leaving screening. The rarity denominator still counts every entry.
        for (edge, _) in storedHits {
            coveringEntryCounts[edge] += 1
            for coveringIndex in coveringEntries[edge] {
                cachedScores[coveringIndex] = nil
            }
            if isParentEligible {
                coveringEntries[edge].append(index)
            }
        }
        tierPrefixSumsValid = false
        return .admitted(index: index, tier: tier)
    }

    // MARK: - Champion Archive

    /// Claims every cell of the entry's covered edges that it wins by shortlex comparison, evicting dethroned entries whose cell count returns to zero from parent selection.
    ///
    /// One comparison per hit edge on admission; admissions are rare, so this never touches the per-attempt path. Eviction is deterministic: only championship arithmetic removes an entry, never insertion order.
    private func claimChampionships(for index: Int) {
        let sequence = entries[index].sequence
        for (edge, _) in entries[index].hits {
            guard let incumbentIndex = edgeChampions[edge] else {
                edgeChampions[edge] = index
                championCounts[index] += 1
                continue
            }
            guard championOrderPrecedes(sequence, entries[incumbentIndex].sequence) else {
                continue
            }
            edgeChampions[edge] = index
            championCounts[index] += 1
            championCounts[incumbentIndex] -= 1
            if championCounts[incumbentIndex] == 0 {
                // Linear scan, deliberately: the weighted parent pick maps its random draw through this array's cumulative order, so tier membership must stay an ordered array — a Set's per-process iteration order would break seeded replay. Eviction fires only when an entry loses its last championship, and the scan is cheap at realistic tier sizes; revisit with a measurement, not a Set.
                parentIndices.removeAll { $0 == incumbentIndex }
                removeDonorSpans(forEntryAt: incumbentIndex)
                tierPrefixSumsValid = false
            }
        }
    }

    /// The champion archive's shortlex order: shorter first, ties broken by the first differing element (kind rank, then per-kind payload). Reflexive ties are not-less, so an incumbent keeps its cell against an equal challenger.
    ///
    /// Deliberately not ``ChoiceSequence/shortLexPrecedes(_:)``, the reducer's order: champion comparison runs on every hit edge of every admission and needs one cheap total pass, while the reducer's order adds value-projection tiebreakers the archive does not need.
    private func championOrderPrecedes(_ lhs: ChoiceSequence, _ rhs: ChoiceSequence) -> Bool {
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
            case .zip(true):
                9
            case .zip(false):
                10
        }
    }

    // MARK: - Quarantine

    /// Removes the entry with the given sequence hash from parent selection. A run resumed after a trap quarantines the crash region — densification would otherwise steer the mutation phase straight back into the trap, crash-looping the suite.
    ///
    /// The entry keeps its coverage credit and rarity contributions; only its eligibility as a mutation root is revoked. A hash with no corpus entry (the trapping candidate itself, which died before admission) is remembered so a later identical admission is barred too.
    package func quarantine(sequenceHash: UInt64) {
        quarantinedHashes.insert(sequenceHash)
        parentIndices.removeAll { entries[$0].hash == sequenceHash }
        tierPrefixSumsValid = false
        for index in entries.indices where entries[index].hash == sequenceHash {
            removeDonorSpans(forEntryAt: index)
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

    // MARK: - Mutation Targets

    /// Whether any enabled experiment consumes the graph-targeted mutation tables. False means no entry ever builds a graph.
    private var consumesMutationTargets: Bool {
        experiments.graphMutation || experiments.pairMutation
    }

    /// The parent's graph-targeted mutation tables, built on first use and cached for the entry's lifetime.
    ///
    /// Construction walks the whole graph four times, so it is deferred to the first draw that consumes it: a run with the targeting knobs off never builds one, and an entry admitted and evicted without ever being drawn as a parent never pays. Returns nil when no enabled experiment consumes the tables or the entry is not a mutation parent.
    ///
    /// Construction consumes no PRNG draws, so deferring it leaves seeded replay streams unchanged.
    package func mutationTargets(forParentAt index: Int) -> MutationTargets? {
        guard consumesMutationTargets, entries.indices.contains(index) else {
            return nil
        }
        if let existing = entries[index].mutationTargets {
            return existing
        }
        // A nil layout marks the discovery tier, whose entries are never mutation parents and hold no targetable positions.
        guard entries[index].mutationLayout != nil else {
            return nil
        }
        let targets = MutationTargets(tree: entries[index].tree)
        entries[index].mutationTargets = targets
        return targets
    }

    // MARK: - Donor Index

    /// One donor span for typed crossover: a pick subtree's position range within the sequence of the entry at `entryIndex`.
    struct DonorSpan {
        let entryIndex: Int
        let range: ClosedRange<Int>
    }

    /// Pick-subtree spans of parent-eligible entries, keyed by pick-site fingerprint. Rows are admission-time facts about immutable sequences, so a row stays valid for the entry's lifetime; an entry's rows are removed when it leaves parent selection (champion dethroning or quarantine) so the donor set tracks the parent-selection domain.
    private(set) var donorSpansByFingerprint: [UInt64: [DonorSpan]] = [:]

    /// The fingerprints each entry contributed rows under, so eviction visits only that entry's keys. Parallel to `entries`.
    private var donorFingerprints: [[UInt64]] = []

    /// Registers the entry's active pick subtrees as crossover donors.
    private func registerDonorSpans(forEntryAt index: Int, graph: ChoiceGraph) {
        var fingerprints: [UInt64] = []
        for (fingerprint, nodeIDs) in graph.selfSimilarityGroups {
            var didRegister = false
            for nodeID in nodeIDs {
                guard let range = graph.nodes[nodeID].positionRange else {
                    continue
                }
                donorSpansByFingerprint[fingerprint, default: []].append(
                    DonorSpan(entryIndex: index, range: range)
                )
                didRegister = true
            }
            if didRegister {
                fingerprints.append(fingerprint)
            }
        }
        donorFingerprints[index] = fingerprints
    }

    /// Removes every donor row belonging to the entry, on its eviction from parent selection.
    ///
    /// Touches only the entry's own keys. Scanning the whole index made eviction O(donor population), and champion dethroning fires often enough under `championArchive` to make that quadratic.
    private func removeDonorSpans(forEntryAt index: Int) {
        for fingerprint in donorFingerprints[index] {
            donorSpansByFingerprint[fingerprint]?.removeAll { $0.entryIndex == index }
            if donorSpansByFingerprint[fingerprint]?.isEmpty == true {
                donorSpansByFingerprint.removeValue(forKey: fingerprint)
            }
        }
        donorFingerprints[index] = []
    }

    // MARK: - Failure Weights

    /// Applies the immediate densification boost when a child of `parentIndex` fails, before reduction classifies the failure.
    package func applyProvisionalFailureBoost(toParentAt parentIndex: Int) {
        setFailureBoost(FuzzTunables.provisionalFailureBoost, at: parentIndex)
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
        let boost = switch (isNewCluster, clusterCapReached) {
            case (true, _): FuzzTunables.newClusterFailureBoost
            case (_, true): 1.0
            default: 1.0 + (FuzzTunables.existingClusterFailureBoost - 1.0) / Double(max(1, clusterInstanceCount))
        }
        setFailureBoost(boost, at: parentIndex)
    }

    private func setFailureBoost(_ boost: Double, at index: Int) {
        guard entries.indices.contains(index), entries[index].failureBoost != boost else {
            return
        }
        entries[index].failureBoost = boost
        cachedScores[index] = nil
        tierPrefixSumsValid = false
    }

    // MARK: - Parent Selection

    /// The parent-selection score of the entry at `index`, computing and caching it if dirty.
    package func score(at index: Int) -> Double {
        if let cached = cachedScores[index] {
            return cached
        }
        let entry = entries[index]
        var rarity = 0.0
        for (edge, _) in entry.hits {
            rarity += 1.0 / Double(coveringEntryCounts[edge])
        }
        var noveltyBonus = 0.0
        for edge in entry.introducedEdges {
            noveltyBonus += 1.0 / Double(coveringEntryCounts[edge])
        }
        let energy = entry.propertyDiscarded ? FuzzTunables.discardParentEnergy : 1.0
        let score = (rarity + FuzzTunables.noveltyBonusWeight * noveltyBonus) * entry.failureBoost * energy
        cachedScores[index] = score
        return score
    }

    /// Picks a mutation parent by weighted random draw over the mutable tier, or nil when the tier is empty.
    ///
    /// The draw lands on the first tier position whose running score sum exceeds `random` times the total, found by binary search over ``tierPrefixSums``. Walking the tier twice per pick (once to sum, once to locate) was 2.4% of a mutation-phase run at a tier of 230 entries, almost all of it the per-entry dynamic exclusivity check on the score cache. Score-weighted selection is the only policy: a uniform epsilon floor and AFLFast-style age decay were both measured worse on every workload tried (see the basin-escape survey in ExhaustDocs).
    ///
    /// - Parameter random: A uniform draw in [0, 1), supplied by the caller so runs stay deterministic under a pinned seed.
    package func pickParent(random: Double) -> (index: Int, entry: CorpusEntry)? {
        guard parentIndices.isEmpty == false else {
            return nil
        }
        if tierPrefixSumsValid == false {
            rebuildTierPrefixSums()
        }
        let totalWeight = tierPrefixSums[tierPrefixSums.count - 1]
        guard totalWeight > 0 else {
            let fallbackIndex = parentIndices[min(
                Int(random * Double(parentIndices.count)),
                parentIndices.count - 1
            )]
            return (fallbackIndex, entries[fallbackIndex])
        }
        let target = random * totalWeight
        var low = 0
        var high = tierPrefixSums.count - 1
        while low < high {
            let middle = (low + high) / 2
            if tierPrefixSums[middle] > target {
                high = middle
            } else {
                low = middle + 1
            }
        }
        let index = parentIndices[low]
        return (index, entries[index])
    }

    /// Recomputes ``tierPrefixSums`` from the current scores in tier order.
    private func rebuildTierPrefixSums() {
        tierPrefixSums.removeAll(keepingCapacity: true)
        tierPrefixSums.reserveCapacity(parentIndices.count)
        var running = 0.0
        for index in parentIndices {
            running += score(at: index)
            tierPrefixSums.append(running)
        }
        tierPrefixSumsValid = true
    }
}
