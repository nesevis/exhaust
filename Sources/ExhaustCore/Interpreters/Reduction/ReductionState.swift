//
//  ReductionState.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

/// Mutable state for the reduction cycle, including the current sequence, tree, encoder instances, and ordering.
///
/// Allocated once per reduction invocation and passed to each leg method by reference. Using a class avoids Swift exclusivity conflicts when leg methods pass encoder properties to helper methods like ``runAdaptive(_:decoder:targets:structureChanged:budget:)``.
final class ReductionState<Output> {
    // Immutable context
    let gen: ReflectiveGenerator<Output>
    let property: (Output) -> Bool
    let config: Interpreters.BonsaiReducerConfiguration
    let hasBind: Bool
    let isInstrumented: Bool
    let collectStats: Bool

    // Mutable reduction state
    var sequence: ChoiceSequence
    var tree: ChoiceTree
    var output: Output
    var fallbackTree: ChoiceTree?
    var bindIndex: BindSpanIndex?
    var bestSequence: ChoiceSequence
    var bestOutput: Output
    var spanCache: SpanCache
    var dominance: EncoderDominance
    var rejectCache = Set<UInt64>(minimumCapacity: 512)
    var convergenceCache = ConvergenceCache()
    var edgeObservations: [Int: EdgeObservation] = [:]
    var phaseTracker = PhaseTracker()
    var statsCycleOutcomes: [CycleOutcome] = []
    var convergenceInstrumentation: ConvergenceInstrumentation?

    /// The ``ChoiceGraph`` built from the current tree for Phase 2 validation. Built alongside the CDG and compared when instrumented. Not consumed by any encoder — read-only.
    var choiceGraph: ChoiceGraph?

    /// The current cycle number, set by the scheduler at the top of each cycle.
    var currentCycle = 0

    /// Whether the tree needs re-materialization with picks before branch encoders can run.
    ///
    /// Set on every acceptance. Cleared after ``runBranchSimplification(budget:)`` performs the materialization. Avoids redundant O(n) materializations when 1a is re-entered after 1b or 1c successes on an unchanged sequence.
    var branchTreeDirty = true

    // MARK: - Stats Tracking (cumulative, not included in Snapshot)

    /// Per-encoder probe counts accumulated across all cycles.
    var encoderProbes: [EncoderName: Int] = [:]

    /// Per-encoder probe counts that were accepted by the decoder.
    var encoderProbesAccepted: [EncoderName: Int] = [:]

    /// Per-encoder probe counts that hit the reject cache before decoding.
    var encoderProbesRejectedByCache: [EncoderName: Int] = [:]

    /// Per-encoder probe counts that were materialized but rejected by the decoder.
    var encoderProbesRejectedByDecoder: [EncoderName: Int] = [:]

    /// Sequence hash at which each encoder last exhausted with zero acceptances. When the current sequence hashes to the same value, `runComposable` skips the encoder entirely — no new reduction opportunities exist on an unchanged sequence.
    private var exhaustionFingerprints: [EncoderName: UInt64] = [:]

    /// Per-fingerprint filter predicate observations accumulated across all materializations.
    var filterObservations: [UInt64: FilterObservation] = [:]

    /// Total materialization attempts (decoder invocations) during reduction.
    ///
    /// Accumulated by `runComposable` (deferred block), `runStructuralDeletion` (manual delta for antichain and mutation pool direct decodes), and `runKleisliExploration` (manual accumulation). Any new direct `decoder.decode()` call outside `runComposable` must manually accumulate into this field.
    var totalMaterializations: Int = 0

    // Decision tree profiling counters
    var convergedCoordinatesAtPhaseTwoStart: Int = 0
    var totalValueCoordinatesAtPhaseTwoStart: Int = 0
    var fibreExceededExhaustiveThreshold: Int = 0
    var pairwiseOnExhaustibleFibre: Int = 0
    var fibreZeroValueStarts: Int = 0
    var futileCompositions: Int = 0
    var compositionEdgesAttempted: Int = 0
    var convergenceTransfersAttempted: Int = 0
    var convergenceTransfersValidated: Int = 0
    var convergenceTransfersStale: Int = 0
    var verificationSweepProbes: Int = 0
    var verificationSweepFoundStaleness: Bool = false
    var fibrePredictionCorrect: Int = 0
    var fibrePredictionWrong: Int = 0
    var zeroingDependencyCount: Int = 0
    var fibreExhaustedCleanCount: Int = 0
    var fibreExhaustedWithFailureCount: Int = 0
    var fibreBailCount: Int = 0
    var statsCycles: Int = 0

    /// Extracts accumulated statistics from this reduction run.
    func extractStats() -> ReductionStats {
        var stats = ReductionStats()
        stats.encoderProbes = encoderProbes.filter { $0.value > 0 }
        stats.encoderProbesAccepted = encoderProbesAccepted.filter { $0.value > 0 }
        stats.encoderProbesRejectedByCache = encoderProbesRejectedByCache.filter { $0.value > 0 }
        stats.encoderProbesRejectedByDecoder = encoderProbesRejectedByDecoder.filter { $0.value > 0 }
        stats.totalMaterializations = totalMaterializations
        stats.cycles = statsCycles
        stats.convergedCoordinatesAtPhaseTwoStart = convergedCoordinatesAtPhaseTwoStart
        stats.totalValueCoordinatesAtPhaseTwoStart = totalValueCoordinatesAtPhaseTwoStart
        stats.fibreExceededExhaustiveThreshold = fibreExceededExhaustiveThreshold
        stats.pairwiseOnExhaustibleFibre = pairwiseOnExhaustibleFibre
        stats.fibreZeroValueStarts = fibreZeroValueStarts
        stats.futileCompositions = futileCompositions
        stats.compositionEdgesAttempted = compositionEdgesAttempted
        stats.convergenceTransfersAttempted = convergenceTransfersAttempted
        stats.convergenceTransfersValidated = convergenceTransfersValidated
        stats.convergenceTransfersStale = convergenceTransfersStale
        stats.verificationSweepProbes = verificationSweepProbes
        stats.verificationSweepFoundStaleness = verificationSweepFoundStaleness
        stats.fibrePredictionCorrect = fibrePredictionCorrect
        stats.fibrePredictionWrong = fibrePredictionWrong
        stats.zeroingDependencyCount = zeroingDependencyCount
        stats.fibreExhaustedCleanCount = fibreExhaustedCleanCount
        stats.fibreExhaustedWithFailureCount = fibreExhaustedWithFailureCount
        stats.fibreBailCount = fibreBailCount
        stats.cycleOutcomes = statsCycleOutcomes
        stats.filterObservations = filterObservations
        return stats
    }

    /// Snapshot of accumulated filter observations for ``ReductionContext``, or `nil` if empty.
    var filterValiditySnapshot: [UInt64: FilterObservation]? {
        filterObservations.isEmpty ? nil : filterObservations
    }

    // MARK: - State View

    /// Builds a read-only view of this state for strategy planning decisions.
    var view: ReductionStateView {
        ReductionStateView(
            allValueCoordinatesConverged: allValueCoordinatesConverged(),
            cycleNumber: currentCycle,
            hasDeletionTargets: pruneOrder.isEmpty == false,
            hasBranchTargets: tree.containsPicks,
            hasBind: hasBind,
            dependencyGraph: buildDAG()
        )
    }

    // MARK: - Fibre Descent Gating

    /// Returns true when every value coordinate is either cached or already at its reduction target.
    ///
    /// Used by the fibre descent gate (signal 4): when all coordinates are effectively converged AND base descent made no structural progress AND Phase 2 stalled last cycle, further Phase 2 probes would only re-confirm floors — skip it.
    ///
    /// A coordinate is effectively converged if:
    /// - It has a cached convergence floor (binary search ran and converged), OR
    /// - Its current value equals its reduction target (nothing to reduce — binary search would skip it).
    func allValueCoordinatesConverged() -> Bool {
        var hasAnyValue = false
        for index in 0 ..< sequence.count {
            guard let value = sequence[index].value else { continue }
            hasAnyValue = true
            // A coordinate is converged if binary search has a cached floor at or below the current value.
            if let origin = convergenceCache.convergedOrigin(at: index) {
                if value.choice.bitPattern64 <= origin.bound {
                    continue
                }
                return false
            }
            // No cache entry — check if the value is already at its reduction target.
            let isWithinRecordedRange =
                value.isRangeExplicit
                    && value.choice.fits(in: value.validRange)
            let targetBitPattern = isWithinRecordedRange
                ? value.choice.reductionTarget(in: value.validRange)
                : value.choice.semanticSimplest.bitPattern64
            if value.choice.bitPattern64 == targetBitPattern {
                continue
            }
            return false
        }
        return hasAnyValue
    }

    // MARK: - Snapshot

    /// A point-in-time copy of all mutable reduction state for rollback on fingerprint boundary crossing.
    ///
    /// Captures every field that ``accept(_:structureChanged:)`` can modify. Restoring a snapshot returns the reducer to exactly the state it was in before the snapshotted acceptance.
    struct Snapshot {
        let sequence: ChoiceSequence
        let tree: ChoiceTree
        let output: Output
        let fallbackTree: ChoiceTree?
        let bindIndex: BindSpanIndex?
        let bestSequence: ChoiceSequence
        let bestOutput: Output
        let branchTreeDirty: Bool
        let spanCache: SpanCache
        let dominance: EncoderDominance
        let convergenceCache: ConvergenceCache
        let rejectCache: Set<UInt64>
        let edgeObservations: [Int: EdgeObservation]
    }

    // Closed reductions
    var branchProjectionPass = BranchProjectionPass()
    var freeCoordinateProjectionPass = FreeCoordinateProjectionPass()
    var humanReadableOrderingPass = HumanReadableOrderingPass()

    // Encoders
    var promoteDirectDescendantEncoder = BranchSimplificationEncoder(strategy: .promoteDirectDescendant)
    var promoteBranchesEncoder = BranchSimplificationEncoder(strategy: .promote)
    var pivotBranchesEncoder = BranchSimplificationEncoder(strategy: .pivot)
    var bindSubstitutionEncoder = BindSubstitutionEncoder()
    var swapSiblingsEncoder = SiblingSwapEncoder()
    var zeroValueEncoder = ZeroValueEncoder()
    var binarySearchToZeroEncoder = BinarySearchToSemanticSimplestEncoder()
    var reduceFloatEncoder = ReduceFloatEncoder()
    var contiguousWindowEncoder = ContiguousWindowDeletionEncoder()
    var beamSearchEncoder: BeamSearchDeletionEncoder
    var tandemEncoder = RedistributeByTandemReductionEncoder()
    var redistributeEncoder = RedistributeAcrossValueContainersEncoder()
    var antichainDeletionEncoder = AntichainDeletionEncoder()
    var productSpaceBatchEncoder = ProductSpaceBatchEncoder()
    var productSpaceAdaptiveEncoder = ProductSpaceAdaptiveEncoder()

    /// Value encoder ordering for leaf-range passes in fibre descent.
    ///
    /// Diverges from ``trainOrder`` via move-to-front within the leaf-range loop.
    var snipOrder: [ReductionScheduler.ValueEncoderSlot] =
        ReductionScheduler.ValueEncoderSlot.allCases

    /// Deletion encoder ordering for structural deletion in base descent.
    var pruneOrder: [ReductionScheduler.DeletionEncoderSlot] =
        ReductionScheduler.DeletionEncoderSlot.allCases

    /// Value encoder ordering for the covariant depth sweep in fibre descent.
    ///
    /// Starts identical to ``snipOrder`` each cycle; diverges via independent move-to-front.
    var trainOrder: [ReductionScheduler.ValueEncoderSlot] =
        ReductionScheduler.ValueEncoderSlot.allCases

    init(
        gen: ReflectiveGenerator<Output>,
        property: @escaping (Output) -> Bool,
        config: Interpreters.BonsaiReducerConfiguration,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        output: Output,
        initialTree: ChoiceTree,
        collectStats: Bool = false
    ) {
        self.gen = gen
        self.property = property
        self.config = config
        self.sequence = sequence
        self.tree = tree
        self.output = output
        hasBind = initialTree.containsBind
        isInstrumented = ExhaustLog.isEnabled(.debug, for: .reducer)
        self.collectStats = collectStats
        bindIndex = hasBind ? BindSpanIndex(from: sequence) : nil
        fallbackTree = hasBind ? tree : nil
        bestSequence = sequence
        bestOutput = output
        spanCache = SpanCache()
        dominance = EncoderDominance()
        beamSearchEncoder = BeamSearchDeletionEncoder(
            beamTuning: config.alignedDeletionBeamSearchTuning
        )
        convergenceInstrumentation = isInstrumented ? ConvergenceInstrumentation() : nil
        choiceGraph = isInstrumented ? ChoiceGraph.build(from: tree) : nil
    }
}

// MARK: - Helpers

extension ReductionState {
    func accept(_ result: ReductionResult<Output>, structureChanged: Bool) {
        phaseTracker.recordAcceptance(structural: structureChanged)
        let oldSequence = sequence
        sequence = result.sequence
        tree = result.tree
        output = result.output
        fallbackTree = result.tree
        branchTreeDirty = true
        if structureChanged {
            spanCache.invalidate()
            // For bind-free generators, structural changes are pure deletions.
            // Remap convergence entries to their new positions instead of
            // invalidating them, so fibre descent can warm-start from cached
            // floors on the next pass. The remap method falls back to
            // invalidateAll() if the new sequence is not a strict subsequence.
            if hasBind == false {
                convergenceCache.remap(from: oldSequence, to: sequence)
            } else {
                convergenceCache.invalidateAll()
            }
            edgeObservations.removeAll(keepingCapacity: true)
            bindIndex = hasBind ? BindSpanIndex(from: sequence) : nil
            if isInstrumented {
                choiceGraph = ChoiceGraph.build(from: tree)
            }
        } else if isInstrumented {
            choiceGraph?.invalidateDerivedEdges()
        }
        // Convergence cache correctness for value-only changes (redistribution) relies on positions being stable: stale bounds produce harmless no-op searches (lo > hi), not incorrect overshoots. If a value-permuting encoder is added, use convergenceCache.invalidateWhereMoved to drop stale entries.
        if hasBind {
            bestSequence = sequence
            bestOutput = output
        } else if sequence.shortLexPrecedes(bestSequence) {
            bestSequence = sequence
            bestOutput = output
        }
    }

    /// Invalidates convergence cache entries for coordinates that share a bind scope with any changed value.
    ///
    /// When a value changes at index *i* within a bind region's span, other coordinates in the same region may have converged in a context that included the old value at *i*. Those converged origins are stale: the property's behavior at those coordinates can differ now that *i* changed.
    private func invalidateConvergenceCacheSiblings(
        oldSequence: ChoiceSequence,
        newSequence: ChoiceSequence,
        bindIndex: BindSpanIndex
    ) {
        let count = min(oldSequence.count, newSequence.count)
        for i in 0 ..< count where oldSequence[i] != newSequence[i] {
            for region in bindIndex.regions where region.bindSpanRange.contains(i) {
                convergenceCache.invalidate(in: region.bindSpanRange)
            }
        }
    }

    // MARK: - ComposableEncoder runner

    /// Runs a composable encoder against a decoder, tracking materializations.
    ///
    /// The encoder derives its own targets from `positionRange` rather than receiving a pre-extracted ``TargetSet``.
    func runComposable(
        _ encoder: some ComposableEncoder,
        decoder: SequenceDecoder,
        positionRange: ClosedRange<Int>,
        context: ReductionContext,
        structureChanged: Bool,
        budget: inout ReductionScheduler.LegBudget,
        fingerprintGuard: StructuralFingerprint? = nil
    ) throws -> Bool {
        guard budget.isExhausted == false else { return false }
        if dominance.shouldSkip(encoder.name, phase: encoder.phase) { return false }
        let sequenceHash = ZobristHash.hash(of: sequence)
        if encoder.phase == .structuralDeletion,
           exhaustionFingerprints[encoder.name] == sequenceHash
        { return false }
        let startSeqLen = sequence.count
        let startSequenceForCacheInvalidation = hasBind ? sequence : nil
        // Capture the base sequence for incremental hashing. Encoder probes are
        // derived from this snapshot — even after acceptance changes self.sequence,
        // the diff between probe and baseSequence stays small.
        let baseSequence = sequence
        var encoder = encoder
        encoder.start(
            sequence: sequence,
            tree: tree,
            positionRange: positionRange,
            context: context
        )
        let cacheSalt = decoder.rejectCacheSalt
        var lastAccepted = false
        var anyAccepted = false
        var probes = 0
        var accepted = 0
        // Per-encoder rejection breakdown for the wasted-mats investigation.
        var cacheHitCount = 0
        var decoderRejectCount = 0
        let budgetBefore = budget.used
        var localFilterObservations: [UInt64: FilterObservation] = [:]
        defer {
            if collectStats {
                encoderProbes[encoder.name, default: 0] += probes
                encoderProbesAccepted[encoder.name, default: 0] += accepted
                encoderProbesRejectedByCache[encoder.name, default: 0] += cacheHitCount
                encoderProbesRejectedByDecoder[encoder.name, default: 0] += decoderRejectCount
                totalMaterializations += (budget.used - budgetBefore)
            }
            for (fingerprint, observation) in localFilterObservations {
                if filterObservations[fingerprint] == nil {
                    filterObservations[fingerprint] = FilterObservation()
                }
                filterObservations[fingerprint]!.attempts += observation.attempts
                filterObservations[fingerprint]!.passes += observation.passes
            }
        }
        var lastDecodingReport: DecodingReport?
        while let probe = encoder.nextProbe(lastAccepted: lastAccepted) {
            guard budget.isExhausted == false else { break }
            probes += 1
            let probeHash = ZobristHash.incrementalHash(
                baseHash: sequenceHash,
                baseSequence: baseSequence,
                probe: probe
            )
            let cacheKey = probeHash &+ cacheSalt
            if rejectCache.contains(cacheKey) {
                lastAccepted = false
                cacheHitCount += 1
                continue
            }
            if let result = try decoder.decode(
                candidate: probe, gen: gen, tree: tree,
                originalSequence: sequence, property: property,
                filterObservations: &localFilterObservations,
                precomputedHash: probeHash
            ) {
                budget.recordMaterialization()
                phaseTracker.recordInvocation()
                lastDecodingReport = result.decodingReport
                if let guardPrint = fingerprintGuard {
                    let snap = makeSnapshot()
                    accept(result, structureChanged: structureChanged)
                    if let currentBindIndex = bindIndex,
                       StructuralFingerprint.from(
                           sequence, bindIndex: currentBindIndex
                       ) != guardPrint
                    {
                        phaseTracker.revertAcceptance(structural: structureChanged)
                        restoreSnapshot(snap)
                        lastAccepted = false
                        break
                    }
                } else {
                    accept(result, structureChanged: structureChanged)
                }
                lastAccepted = true
                anyAccepted = true
                accepted += 1
            } else {
                budget.recordMaterialization()
                phaseTracker.recordInvocation()
                lastAccepted = false
                rejectCache.insert(cacheKey)
                decoderRejectCount += 1
            }
        }
        let harvested = encoder.convergenceRecords
        let cacheReliable = lastDecodingReport?.isReliableForConvergenceCache ?? true
        for (index, convergedOrigin) in harvested {
            if cacheReliable {
                convergenceCache.record(index: index, convergedOrigin: convergedOrigin)
            }
            if convergedOrigin.signal == .zeroingDependency {
                zeroingDependencyCount += 1
            }
        }
        if convergenceInstrumentation != nil {
            for (index, convergedOrigin) in harvested {
                convergenceInstrumentation?.records.append(
                    ConvergenceInstrumentation.ConvergenceRecord(
                        coordinateIndex: index,
                        convergedValue: convergedOrigin.bound,
                        cycle: currentCycle
                    )
                )
            }
            convergenceInstrumentation?.totalEncoderConvergences += harvested.count
        }
        if anyAccepted,
           convergenceCache.isEmpty == false,
           let startSeq = startSequenceForCacheInvalidation,
           let index = bindIndex
        {
            invalidateConvergenceCacheSiblings(
                oldSequence: startSeq,
                newSequence: sequence,
                bindIndex: index
            )
        }

        if anyAccepted {
            dominance.recordSuccess(encoder.name)
            if encoder.phase == .structuralDeletion {
                exhaustionFingerprints[encoder.name] = nil
            }
        } else if probes > 0, encoder.phase == .structuralDeletion {
            exhaustionFingerprints[encoder.name] = sequenceHash
        }
        if isInstrumented {
            if probes > 0 {
                let event = anyAccepted
                    ? "encoder_accepted"
                    : "encoder_exhausted"
                ExhaustLog.debug(
                    category: .reducer,
                    event: event,
                    metadata: [
                        "encoder": encoder.name.rawValue,
                        "probes": "\(probes)",
                        "accepted": "\(accepted)",
                        "seq_len": "\(startSeqLen)→\(sequence.count)",
                        "output": anyAccepted ? "\(output)" : "",
                    ]
                )
            } else {
                ExhaustLog.debug(category: .reducer, event: "encoder_no_probes", metadata: [
                    "encoder": encoder.name.rawValue,
                ])
            }
        }
        return anyAccepted
    }

    func makeDeletionDecoder(at depth: Int) -> SequenceDecoder {
        let context = DecoderContext(
            depth: .specific(depth),
            bindIndex: bindIndex,
            fallbackTree: fallbackTree,
            strictness: .relaxed
        )
        return SequenceDecoder.for(context)
    }

    /// Decoder for speculative deletion: PRNG fallback for deleted entries, enabling repair with fresh (possibly shorter) values that satisfy filters.
    func makeSpeculativeDecoder() -> SequenceDecoder {
        .guided(fallbackTree: nil, materializePicks: true, usePRNGFallback: true)
    }

    func makeDepthZeroDecoder() -> SequenceDecoder {
        let context = DecoderContext(
            depth: .specific(0),
            bindIndex: bindIndex,
            fallbackTree: fallbackTree,
            strictness: .normal
        )
        return SequenceDecoder.for(context)
    }

    /// Returns a snapshot of all mutable reduction state.
    func makeSnapshot() -> Snapshot {
        Snapshot(
            sequence: sequence,
            tree: tree,
            output: output,
            fallbackTree: fallbackTree,
            bindIndex: bindIndex,
            bestSequence: bestSequence,
            bestOutput: bestOutput,
            branchTreeDirty: branchTreeDirty,
            spanCache: spanCache,
            dominance: dominance,
            convergenceCache: convergenceCache,
            rejectCache: rejectCache,
            edgeObservations: edgeObservations
        )
    }

    /// Restores all mutable reduction state from a snapshot, undoing any acceptances made after it was taken.
    func restoreSnapshot(_ snapshot: Snapshot) {
        sequence = snapshot.sequence
        tree = snapshot.tree
        output = snapshot.output
        fallbackTree = snapshot.fallbackTree
        bindIndex = snapshot.bindIndex
        bestSequence = snapshot.bestSequence
        bestOutput = snapshot.bestOutput
        branchTreeDirty = snapshot.branchTreeDirty
        spanCache = snapshot.spanCache
        dominance = snapshot.dominance
        convergenceCache = snapshot.convergenceCache
        rejectCache = snapshot.rejectCache
        edgeObservations = snapshot.edgeObservations
    }
}

// MARK: - Encoder Ordering

extension ReductionState {
    /// Computes cost-based encoder ordering for the current sequence.
    ///
    /// Called once per cycle. When `depthFilter` is non-nil, cost estimation extracts spans at that bind depth only.
    func computeEncoderOrdering(depthFilter: Int? = nil) {
        let fullRange = 0 ... max(0, sequence.count - 1)
        let orderingContext = ReductionContext(bindIndex: bindIndex, depthFilter: depthFilter)
        var valueCosts = [ReductionScheduler.ValueEncoderSlot: Int]()
        for slot in ReductionScheduler.ValueEncoderSlot.allCases {
            let cost: Int? = switch slot {
            case .zeroValue:
                zeroValueEncoder.estimatedCost(
                    sequence: sequence, tree: tree,
                    positionRange: fullRange,
                    context: orderingContext
                )
            case .binarySearchToZero:
                binarySearchToZeroEncoder.estimatedCost(
                    sequence: sequence, tree: tree,
                    positionRange: fullRange,
                    context: orderingContext
                )
            case .reduceFloat:
                reduceFloatEncoder.estimatedCost(
                    sequence: sequence, tree: tree,
                    positionRange: fullRange,
                    context: orderingContext
                )
            }
            if let cost { valueCosts[slot] = cost }
        }

        var deletionCosts = [ReductionScheduler.DeletionEncoderSlot: Int]()
        // Global span count across all depths, routed through SpanCache to avoid
        // redundant O(n) walks when subsequent phases also extract spans.
        let containerCount = spanCache.allContainerSpanCount(from: sequence)
        let allSpanCount = spanCache.allValueSpanCount(from: sequence)
        for slot in ReductionScheduler.DeletionEncoderSlot.allCases {
            let spanCount: Int = switch slot {
            case .containerSpans, .alignedWindows, .randomRepairDelete: containerCount
            case .sequenceElements, .sequenceBoundaries, .freeStandingValues: allSpanCount
            }
            if spanCount > 0 {
                deletionCosts[slot] = spanCount * 10
            }
        }

        snipOrder = ReductionScheduler.ValueEncoderSlot.allCases
            .filter { valueCosts[$0] != nil }
            .sorted { (valueCosts[$0] ?? 0) < (valueCosts[$1] ?? 0) }

        // trainOrder starts identical to snipOrder; move-to-front diverges during cycle.
        trainOrder = snipOrder

        pruneOrder = ReductionScheduler.DeletionEncoderSlot.allCases
            .filter { deletionCosts[$0] != nil }
            .sorted { (deletionCosts[$0] ?? 0) < (deletionCosts[$1] ?? 0) }
    }
}

