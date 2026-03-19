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

    // Mutable reduction state
    var sequence: ChoiceSequence
    var tree: ChoiceTree
    var output: Output
    var fallbackTree: ChoiceTree?
    var bindIndex: BindSpanIndex?
    var bestSequence: ChoiceSequence
    var bestOutput: Output
    var spanCache: SpanCache
    var lattice: DominanceLattice
    var rejectCache = Set<UInt64>(minimumCapacity: 512)

    /// Whether the tree needs re-materialization with picks before branch encoders can run.
    ///
    /// Set on every acceptance. Cleared after ``runBranchSimplification(budget:)`` performs the materialization. Avoids redundant O(n) materializations when 1a is re-entered after 1b or 1c successes on an unchanged sequence.
    var branchTreeDirty = true

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
        let lattice: DominanceLattice
    }

    // Encoders
    var promoteBranchesEncoder = DeleteByBranchPromotionEncoder()
    var pivotBranchesEncoder = DeleteByBranchPivotEncoder()
    var deleteContainerSpans = DeleteContainerSpansEncoder()
    var deleteSequenceElements = DeleteSequenceElementsEncoder()
    var deleteSequenceBoundaries = DeleteSequenceBoundariesEncoder()
    var deleteFreeStandingValues = DeleteFreeStandingValuesEncoder()
    var randomRepairDelete = DeleteContainerSpansWithRandomRepairEncoder()
    var zeroValueEncoder = ZeroValueEncoder()
    var binarySearchToZeroEncoder = BinarySearchToSemanticSimplestEncoder()
    var binarySearchToTargetEncoder = BinarySearchToRangeMinimumEncoder()
    var reduceFloatEncoder = ReduceFloatEncoder()
    var deleteAlignedWindowsEncoder: DeleteAlignedWindowsEncoder
    var tandemEncoder = RedistributeByTandemReductionEncoder()
    var redistributeEncoder = RedistributeAcrossValueContainersEncoder()
    var productSpaceBatchEncoder = ProductSpaceBatchEncoder()
    var productSpaceAdaptiveEncoder = ProductSpaceAdaptiveEncoder()

    // Encoder ordering: move-to-front per leg, persists across cycles.
    var snipOrder: [ReductionScheduler.ValueEncoderSlot] = ReductionScheduler.ValueEncoderSlot.allCases
    var pruneOrder: [ReductionScheduler.DeletionEncoderSlot] = ReductionScheduler.DeletionEncoderSlot.allCases
    var trainOrder: [ReductionScheduler.ValueEncoderSlot] = ReductionScheduler.ValueEncoderSlot.allCases

    init(
        gen: ReflectiveGenerator<Output>,
        property: @escaping (Output) -> Bool,
        config: Interpreters.BonsaiReducerConfiguration,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        output: Output,
        initialTree: ChoiceTree
    ) {
        self.gen = gen
        self.property = property
        self.config = config
        self.sequence = sequence
        self.tree = tree
        self.output = output
        self.hasBind = initialTree.containsBind
        self.isInstrumented = ExhaustLog.isEnabled(.debug, for: .reducer)
        self.bindIndex = hasBind ? BindSpanIndex(from: sequence) : nil
        self.fallbackTree = hasBind ? tree : nil
        self.bestSequence = sequence
        self.bestOutput = output
        self.spanCache = SpanCache()
        self.lattice = DominanceLattice()
        self.deleteAlignedWindowsEncoder = DeleteAlignedWindowsEncoder(
            beamTuning: config.alignedDeletionBeamSearchTuning
        )
    }
}

// MARK: - Helpers

extension ReductionState {
    func accept(_ result: ReductionResult<Output>, structureChanged: Bool) {
        sequence = result.sequence
        tree = result.tree
        output = result.output
        fallbackTree = result.tree
        branchTreeDirty = true
        if structureChanged {
            spanCache.invalidate()
            bindIndex = hasBind ? BindSpanIndex(from: sequence) : nil
            if config.useReductionMaterializer == false {
                let seed = ZobristHash.hash(of: sequence)
                if case let .success(reDerivedOutput, reDerivedSequence, reDerivedTree) =
                    GuidedMaterializer.materialize(gen, prefix: sequence, seed: seed, fallbackTree: tree),
                    property(reDerivedOutput) == false,
                    sequence.shortLexPrecedes(reDerivedSequence) == false
                {
                    sequence = reDerivedSequence
                    tree = reDerivedTree
                    output = reDerivedOutput
                    fallbackTree = reDerivedTree
                }
            }
        }
        if hasBind {
            bestSequence = sequence
            bestOutput = output
        } else if sequence.shortLexPrecedes(bestSequence) {
            bestSequence = sequence
            bestOutput = output
        }
    }

    /// Runs a batch encoder against a decoder, tracking materializations. Returns true if a candidate was accepted.
    func runBatch(
        _ encoder: some BatchEncoder,
        decoder: SequenceDecoder,
        targets: TargetSet,
        structureChanged: Bool,
        budget: inout ReductionScheduler.LegBudget
    ) throws -> Bool {
        guard budget.isExhausted == false else { return false }
        if lattice.shouldSkip(encoder.name, phase: encoder.phase) { return false }
        let startSeqLen = sequence.count
        let cacheSalt = decoder.rejectCacheSalt
        var probes = 0
        for candidate in encoder.encode(sequence: sequence, targets: targets) {
            guard budget.isExhausted == false else { break }
            probes += 1
            let cacheKey = ZobristHash.hash(of: candidate) &+ cacheSalt
            if rejectCache.contains(cacheKey) {
                budget.recordMaterialization()
                continue
            }
            if let result = try decoder.decode(
                candidate: candidate,
                gen: gen,
                tree: tree,
                originalSequence: sequence,
                property: property
            ) {
                budget.recordMaterialization()
                accept(result, structureChanged: structureChanged)
                lattice.recordSuccess(encoder.name)
                if isInstrumented {
                    ExhaustLog.debug(category: .reducer, event: "encoder_accepted", metadata: [
                        "encoder": encoder.name.rawValue, "probes": "\(probes)",
                        "seq_len": "\(startSeqLen)→\(sequence.count)",
                        "output": "\(output)",
                    ])
                }
                return true
            }
            budget.recordMaterialization()
            rejectCache.insert(cacheKey)
        }
        if isInstrumented {
            if probes > 0 {
                ExhaustLog.debug(category: .reducer, event: "encoder_exhausted", metadata: [
                    "encoder": encoder.name.rawValue, "probes": "\(probes)",
                    "seq_len": "\(startSeqLen)",
                ])
            } else {
                ExhaustLog.debug(category: .reducer, event: "encoder_no_probes", metadata: [
                    "encoder": encoder.name.rawValue,
                ])
            }
        }
        return false
    }

    /// Runs an adaptive encoder against a decoder, tracking materializations. Returns true if any probe was accepted.
    ///
    /// - Parameters:
    ///   - fingerprintGuard: When non-nil, enforces a per-acceptance Phase 1/Phase 2 boundary. Before committing each accepted probe, the method takes a snapshot, calls `accept`, then recomputes the ``StructuralFingerprint``. If the fingerprint differs from the guard value, the acceptance is rolled back via the snapshot and the encoder loop terminates immediately. Any clean acceptances committed before the crossing are preserved. This prevents Phase 2 value encoders from accidentally committing structural changes — for example, reducing a nested bind-inner value that changes bound-array length — that belong in Phase 1. The guard requires `structureChanged: hasBind` so that `accept` rebuilds ``BindSpanIndex`` before the fingerprint is recomputed.
    func runAdaptive(
        _ encoder: some AdaptiveEncoder,
        decoder: SequenceDecoder,
        targets: TargetSet,
        structureChanged: Bool,
        budget: inout ReductionScheduler.LegBudget,
        fingerprintGuard: StructuralFingerprint? = nil
    ) throws -> Bool {
        guard budget.isExhausted == false else { return false }
        if lattice.shouldSkip(encoder.name, phase: encoder.phase) { return false }
        let startSeqLen = sequence.count
        var encoder = encoder
        encoder.start(sequence: sequence, targets: targets)
        let cacheSalt = decoder.rejectCacheSalt
        var lastAccepted = false
        var anyAccepted = false
        var probes = 0
        var accepted = 0
        while let probe = encoder.nextProbe(lastAccepted: lastAccepted) {
            guard budget.isExhausted == false else { break }
            probes += 1
            let cacheKey = ZobristHash.hash(of: probe) &+ cacheSalt
            if rejectCache.contains(cacheKey) {
                lastAccepted = false
                continue
            }
            if let result = try decoder.decode(
                candidate: probe, gen: gen, tree: tree,
                originalSequence: sequence, property: property
            ) {
                budget.recordMaterialization()
                if let guardPrint = fingerprintGuard {
                    // Snapshot before accepting so a structural crossing can be fully rolled back.
                    let snap = makeSnapshot()
                    accept(result, structureChanged: structureChanged)
                    // bindIndex is now fresh (structureChanged: hasBind rebuilt it above).
                    // Compare the post-accept fingerprint against the pre-Phase-2 baseline.
                    if let currentBindIndex = bindIndex,
                       StructuralFingerprint.from(tree, bindIndex: currentBindIndex) != guardPrint
                    {
                        // Structural boundary crossed: undo this acceptance and stop the encoder.
                        // Any clean acceptances already committed remain intact.
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
                lastAccepted = false
                rejectCache.insert(cacheKey)
            }
        }
        if anyAccepted {
            lattice.recordSuccess(encoder.name)
        }
        if isInstrumented {
            if probes > 0 {
                ExhaustLog.debug(category: .reducer, event: anyAccepted ? "encoder_accepted" : "encoder_exhausted", metadata: [
                    "encoder": encoder.name.rawValue, "probes": "\(probes)", "accepted": "\(accepted)",
                    "seq_len": "\(startSeqLen)→\(sequence.count)",
                    "output": anyAccepted ? "\(output)" : "",
                ])
            } else {
                ExhaustLog.debug(category: .reducer, event: "encoder_no_probes", metadata: [
                    "encoder": encoder.name.rawValue,
                ])
            }
        }
        return anyAccepted
    }

    func makeDeletionDecoder(at depth: Int) -> SequenceDecoder {
        let context = DecoderContext(depth: .specific(depth), bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .relaxed, useReductionMaterializer: config.useReductionMaterializer)
        return SequenceDecoder.for(context)
    }

    /// Decoder for speculative deletion: PRNG fallback for deleted entries,
    /// enabling repair with fresh (possibly shorter) values that satisfy filters.
    func makeSpeculativeDecoder() -> SequenceDecoder {
        .guided(fallbackTree: nil, materializePicks: config.useReductionMaterializer, usePRNGFallback: true)
    }

    func makeDepthZeroDecoder() -> SequenceDecoder {
        let context = DecoderContext(depth: .specific(0), bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .normal, useReductionMaterializer: config.useReductionMaterializer)
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
            lattice: lattice
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
        lattice = snapshot.lattice
    }

}

// MARK: - Encoder Ordering

extension ReductionState {
    /// Computes cost-based encoder ordering for the current sequence. Called once per cycle.
    func computeEncoderOrdering() {
        var valueCosts = [ReductionScheduler.ValueEncoderSlot: Int]()
        for slot in ReductionScheduler.ValueEncoderSlot.allCases {
            let cost: Int? = switch slot {
            case .zeroValue: zeroValueEncoder.estimatedCost(sequence: sequence, bindIndex: bindIndex)
            case .binarySearchToZero: binarySearchToZeroEncoder.estimatedCost(sequence: sequence, bindIndex: bindIndex)
            case .binarySearchToTarget: binarySearchToTargetEncoder.estimatedCost(sequence: sequence, bindIndex: bindIndex)
            case .reduceFloat: reduceFloatEncoder.estimatedCost(sequence: sequence, bindIndex: bindIndex)
            }
            if let cost { valueCosts[slot] = cost }
        }

        var deletionCosts = [ReductionScheduler.DeletionEncoderSlot: Int]()
        for slot in ReductionScheduler.DeletionEncoderSlot.allCases {
            let cost: Int? = switch slot {
            case .containerSpans: deleteContainerSpans.estimatedCost(sequence: sequence, bindIndex: bindIndex)
            case .sequenceElements: deleteSequenceElements.estimatedCost(sequence: sequence, bindIndex: bindIndex)
            case .sequenceBoundaries: deleteSequenceBoundaries.estimatedCost(sequence: sequence, bindIndex: bindIndex)
            case .freeStandingValues: deleteFreeStandingValues.estimatedCost(sequence: sequence, bindIndex: bindIndex)
            case .alignedWindows: deleteAlignedWindowsEncoder.estimatedCost(sequence: sequence, bindIndex: bindIndex)
            case .randomRepairDelete: randomRepairDelete.estimatedCost(sequence: sequence, bindIndex: bindIndex)
            }
            if let cost { deletionCosts[slot] = cost }
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

// MARK: - Relax-Round

extension ReductionState {
    /// Relax-round: redistributes value magnitude speculatively, then exploits the relaxed state with base descent and fibre descent.
    ///
    /// Categorically, this is a non-monotone endomorphism of the total space — neither cartesian nor vertical, and not a descent step. It breaks the fibred factorisation at the step level and recovers it at the pipeline level: the ``RelaxRoundEncoder`` zeros one value by inflating another (potentially crossing fibres if bind-inner values are redistributed), then standard base descent and fibre descent passes exploit the relaxed state. In Bonsai terms, it sacrifices one leaf to nourish another, then re-prunes and re-shapes the tree, keeping the result only if the whole tree is simpler than before. In plain language, it moves magnitude from one value to another (making the sequence temporarily worse), runs the normal reduction passes on the result, and accepts the outcome only if the round-trip produces a net improvement.
    ///
    /// Pipeline acceptance: final state must shortlex-precede the pre-relaxation checkpoint. ``bestSequence`` and ``bestOutput`` only update if the full pipeline passes — intermediate results are discarded on rollback.
    func runRelaxRound(remaining: inout Int) throws -> Bool {
        // Checkpoint all mutable state, including bestSequence/bestOutput.
        let checkpointSequence = sequence
        let checkpointTree = tree
        let checkpointOutput = output
        let checkpointFallbackTree = fallbackTree
        let checkpointBindIndex = bindIndex
        let checkpointBestSequence = bestSequence
        let checkpointBestOutput = bestOutput

        // Run RelaxRoundEncoder with exact decoder — no fallback, no shortlex check.
        // Exact mode validates values against their explicit ranges, avoiding
        // fallback-induced structural changes that break materialization.
        let speculativeDecoder: SequenceDecoder = .exact()
        var explorationBudget = ReductionScheduler.LegBudget(hardCap: remaining)
        var relaxEncoder = RelaxRoundEncoder()
        relaxEncoder.start(sequence: sequence, targets: .wholeSequence)
        var lastAccepted = false
        var redistributionAccepted = false
        var explorationProbes = 0
        var explorationAccepted = 0
        while let probe = relaxEncoder.nextProbe(lastAccepted: lastAccepted) {
            guard explorationBudget.isExhausted == false else { break }
            explorationProbes += 1
            // Do not consult the shared reject cache — it contains probes rejected
            // by the normal decoder (with shortlex check). The speculative decoder
            // (without shortlex check) may accept those same probes.
            if let result = try speculativeDecoder.decode(
                candidate: probe, gen: gen, tree: tree,
                originalSequence: sequence, property: property
            ) {
                explorationBudget.recordMaterialization()
                // Reject results that grow the sequence — the redistribution should
                // only change values, not add structure. Growth happens when the
                // redistributed values violate a filter, causing PRNG fallback.
                if result.sequence.count > sequence.count {
                    lastAccepted = false
                    continue
                }
                accept(result, structureChanged: hasBind)
                lastAccepted = true
                redistributionAccepted = true
                explorationAccepted += 1
            } else {
                explorationBudget.recordMaterialization()
                lastAccepted = false
            }
        }

        if isInstrumented {
            ExhaustLog.debug(category: .reducer, event: "exploration_redistribute", metadata: [
                "probes": "\(explorationProbes)",
                "accepted": "\(explorationAccepted)",
                "budget_used": "\(explorationBudget.used)",
            ])
        }

        guard redistributionAccepted else {
            // No speculative move found. Restore bestSequence/bestOutput
            // (accept() may have transiently updated them).
            bestSequence = checkpointBestSequence
            bestOutput = checkpointBestOutput
            remaining -= explorationBudget.used
            return false
        }

        // Exploitation: run the standard two-phase pipeline on the relaxed state.
        var exploitRemaining = remaining - explorationBudget.used
        computeEncoderOrdering()
        let (dag, baseProgress) = try runBaseDescent(budget: &exploitRemaining)
        let fibreProgress = try runFibreDescent(budget: &exploitRemaining, dag: dag)

        // Pipeline acceptance: final state must shortlex-precede checkpoint.
        if sequence.shortLexPrecedes(checkpointSequence) {
            bestSequence = sequence
            bestOutput = output
            remaining = exploitRemaining
            if isInstrumented {
                ExhaustLog.debug(category: .reducer, event: "exploration_accepted", metadata: [
                    "seq_len": "\(checkpointSequence.count)→\(sequence.count)",
                    "base_descent": "\(baseProgress)",
                    "fibre_descent": "\(fibreProgress)",
                ])
            }
            return true
        }

        // Rollback all state including bestSequence/bestOutput.
        sequence = checkpointSequence
        tree = checkpointTree
        output = checkpointOutput
        fallbackTree = checkpointFallbackTree
        bindIndex = checkpointBindIndex
        bestSequence = checkpointBestSequence
        bestOutput = checkpointBestOutput
        remaining -= explorationBudget.used
        return false
    }
}
