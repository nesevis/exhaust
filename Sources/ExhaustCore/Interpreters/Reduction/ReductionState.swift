/// Mutable state for the reduction cycle, including the current sequence, tree, encoder instances, and ordering.
///
/// Allocated once per ``ReductionScheduler/run(gen:initialTree:config:property:)`` invocation and passed to each leg method by reference. Using a class avoids Swift exclusivity conflicts when leg methods pass encoder properties to helper methods like ``runAdaptive(_:decoder:targets:structureChanged:budget:)``.
final class ReductionState<Output> {
    // Immutable context
    let gen: ReflectiveGenerator<Output>
    let property: (Output) -> Bool
    let config: Interpreters.BonsaiReducerConfiguration
    let hasBind: Bool
    let isInstrumented: Bool
    let cycleBudget: CycleBudget

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
    var bindAwareRedistributeEncoder = RedistributeAcrossBindRegionsEncoder()
    var bindRootSearchEncoder = BindRootSearchEncoder()
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
        self.cycleBudget = CycleBudget(total: ReductionScheduler.defaultCycleBudgetTotal, legWeights: CycleBudget.defaultWeights())
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
    func accept(_ result: ShrinkResult<Output>, structureChanged: Bool) {
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

    /// Computes an adaptive redistribution budget from the estimated costs of all redistribution encoders, capped at ``ReductionScheduler/defaultRedistributionBudget``.
    ///
    /// For small generators with few values, the budget scales down to avoid wasting materializations on search space that doesn't exist. For large generators, the cap prevents runaway spending.
    var adaptiveRedistributionBudget: Int {
        var total = 0
        if let cost = bindAwareRedistributeEncoder.estimatedCost(sequence: sequence, bindIndex: bindIndex) {
            total += cost
        }
        if let cost = tandemEncoder.estimatedCost(sequence: sequence, bindIndex: bindIndex) {
            total += cost
        }
        if let cost = redistributeEncoder.estimatedCost(sequence: sequence, bindIndex: bindIndex) {
            total += cost
        }
        return min(total, ReductionScheduler.defaultRedistributionBudget)
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

// MARK: - Leg Methods

extension ReductionState {
    /// Runs branch promotion and pivoting. Returns `true` if any branch was accepted.
    func runBranchLeg(remaining: inout Int) throws -> Bool {
        let branchContext = DecoderContext(depth: .specific(0), bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .relaxed, useReductionMaterializer: config.useReductionMaterializer, materializePicks: true)
        let branchDecoder = SequenceDecoder.for(branchContext)
        let target = cycleBudget.initialBudget(for: .branch)
        var branchBudget = ReductionScheduler.LegBudget(hardCap: min(remaining, 2 * target))
        var improved = false

        // Re-materialize with picks so branch encoders see all non-selected alternatives.
        // This is needed because prior legs may have accepted probes with materializePicks=false.
        if case let .success(_, freshTree) = ReductionMaterializer.materialize(
            gen, prefix: sequence, mode: .exact, fallbackTree: fallbackTree,
            materializePicks: true
        ) {
            tree = freshTree
        }

        promoteBranchesEncoder.currentTree = tree
        if try runBatch(promoteBranchesEncoder, decoder: branchDecoder, targets: .wholeSequence, structureChanged: true, budget: &branchBudget) {
            improved = true
        }

        pivotBranchesEncoder.currentTree = tree
        if try runBatch(pivotBranchesEncoder, decoder: branchDecoder, targets: .wholeSequence, structureChanged: true, budget: &branchBudget) {
            improved = true
        }

        remaining -= branchBudget.used
        return improved
    }

    /// Runs the contravariant sweep from max bind depth to 1. Returns the number of accepted probes.
    func runSnipLeg(remaining: inout Int, maxBindDepth: Int, dirtyDepths: Set<Int>) throws -> Int {
        let target = cycleBudget.initialBudget(for: .contravariant)
        var legBudget = ReductionScheduler.LegBudget(hardCap: min(remaining, 2 * target))
        spanCache.invalidate()
        lattice.invalidate()
        var accepted = 0

        if maxBindDepth >= 1 {
            for depth in stride(from: maxBindDepth, through: 1, by: -1) where dirtyDepths.contains(depth) {
                guard legBudget.isExhausted == false else { break }
                lattice.invalidate()
                var depthProgress = true
                while depthProgress, legBudget.isExhausted == false {
                    depthProgress = false
                    let context = DecoderContext(depth: .specific(depth), bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .normal, useReductionMaterializer: config.useReductionMaterializer)
                    let decoder = SequenceDecoder.for(context)
                    let vSpans = spanCache.valueSpans(at: depth, from: sequence, bindIndex: bindIndex)
                    let fSpans = spanCache.floatSpans(at: depth, from: sequence, bindIndex: bindIndex)

                    for slot in snipOrder {
                        guard legBudget.isExhausted == false else { break }
                        switch slot {
                        case .zeroValue:
                            if vSpans.isEmpty == false {
                                if try runAdaptive(zeroValueEncoder, decoder: decoder, targets: .spans(vSpans), structureChanged: false, budget: &legBudget) {
                                    depthProgress = true
                                    accepted += 1
                                    ReductionScheduler.moveToFront(.zeroValue, in: &snipOrder)
                                }
                            }
                        case .binarySearchToZero:
                            if vSpans.isEmpty == false {
                                if try runAdaptive(binarySearchToZeroEncoder, decoder: decoder, targets: .spans(vSpans), structureChanged: false, budget: &legBudget) {
                                    depthProgress = true
                                    accepted += 1
                                    ReductionScheduler.moveToFront(.binarySearchToZero, in: &snipOrder)
                                }
                            }
                        case .binarySearchToTarget:
                            if vSpans.isEmpty == false {
                                if try runAdaptive(binarySearchToTargetEncoder, decoder: decoder, targets: .spans(vSpans), structureChanged: false, budget: &legBudget) {
                                    depthProgress = true
                                    accepted += 1
                                    ReductionScheduler.moveToFront(.binarySearchToTarget, in: &snipOrder)
                                }
                            }
                        case .reduceFloat:
                            if fSpans.isEmpty == false {
                                if try runAdaptive(reduceFloatEncoder, decoder: decoder, targets: .spans(fSpans), structureChanged: false, budget: &legBudget) {
                                    depthProgress = true
                                    accepted += 1
                                    ReductionScheduler.moveToFront(.reduceFloat, in: &snipOrder)
                                }
                            }
                        }
                    }
                }
            }
        }
        remaining -= legBudget.used
        return accepted
    }

    /// Runs the deletion sweep from depth 0 to max. Returns the number of accepted probes.
    func runPruneLeg(remaining: inout Int, maxBindDepth: Int) throws -> Int {
        let target = cycleBudget.initialBudget(for: .deletion)
        var legBudget = ReductionScheduler.LegBudget(hardCap: min(remaining, 2 * target))
        spanCache.invalidate()
        lattice.invalidate()
        var accepted = 0

        for depth in 0 ... maxBindDepth {
            guard legBudget.isExhausted == false else { break }
            lattice.invalidate()
            let depthDecoder = makeDeletionDecoder(at: depth)

            for slot in pruneOrder {
                guard legBudget.isExhausted == false else { break }
                let slotAccepted: Bool = switch slot {
                case .containerSpans:
                    try runAdaptive(deleteContainerSpans, decoder: depthDecoder, targets: .spans(spanCache.deletionTargets(category: slot.spanCategory, depth: depth, from: sequence, bindIndex: bindIndex)), structureChanged: true, budget: &legBudget)
                case .sequenceElements:
                    try runAdaptive(deleteSequenceElements, decoder: depthDecoder, targets: .spans(spanCache.deletionTargets(category: slot.spanCategory, depth: depth, from: sequence, bindIndex: bindIndex)), structureChanged: true, budget: &legBudget)
                case .sequenceBoundaries:
                    try runAdaptive(deleteSequenceBoundaries, decoder: depthDecoder, targets: .spans(spanCache.deletionTargets(category: slot.spanCategory, depth: depth, from: sequence, bindIndex: bindIndex)), structureChanged: true, budget: &legBudget)
                case .freeStandingValues:
                    try runAdaptive(deleteFreeStandingValues, decoder: depthDecoder, targets: .spans(spanCache.deletionTargets(category: slot.spanCategory, depth: depth, from: sequence, bindIndex: bindIndex)), structureChanged: true, budget: &legBudget)
                case .alignedWindows:
                    try runAdaptive(deleteAlignedWindowsEncoder, decoder: depthDecoder, targets: .spans(spanCache.deletionTargets(category: slot.spanCategory, depth: depth, from: sequence, bindIndex: bindIndex)), structureChanged: true, budget: &legBudget)
                case .randomRepairDelete:
                    try runAdaptive(randomRepairDelete, decoder: makeSpeculativeDecoder(), targets: .spans(spanCache.deletionTargets(category: slot.spanCategory, depth: depth, from: sequence, bindIndex: bindIndex)), structureChanged: true, budget: &legBudget)
                }
                if slotAccepted {
                    accepted += 1
                    ReductionScheduler.moveToFront(slot, in: &pruneOrder)
                }
            }
        }
        remaining -= legBudget.used
        return accepted
    }

    /// Runs the covariant sweep at depth 0. Returns the number of accepted probes.
    func runTrainLeg(remaining: inout Int) throws -> Int {
        let target = cycleBudget.initialBudget(for: .covariant)
        var legBudget = ReductionScheduler.LegBudget(hardCap: min(remaining, 2 * target))
        spanCache.invalidate()
        lattice.invalidate()
        let structureChangedOnCovariant = hasBind
        let trainDecoder = makeDepthZeroDecoder()
        var accepted = 0

        // Product-space search: reduce bind-controlling values jointly, then fall back to sequential.
        if hasBind, let bindSpanIndex = bindIndex {
            let prngDecoder: SequenceDecoder = .guided(fallbackTree: nil, usePRNGFallback: true)
            let bindInnerCount = bindSpanIndex.regions.count

            if bindInnerCount <= 3 {
                // Batch: enumerate product space of bind-inner values.
                productSpaceBatchEncoder.bindIndex = bindSpanIndex
                productSpaceBatchEncoder.dag = ChoiceDependencyGraph.build(
                    from: sequence, tree: tree, bindIndex: bindSpanIndex
                )

                // Tier 1: guided replay (clamp bound entries to current tree).
                let guidedDecoder: SequenceDecoder = .guided(
                    fallbackTree: fallbackTree ?? tree
                )
                if try runBatch(
                    productSpaceBatchEncoder, decoder: guidedDecoder,
                    targets: .wholeSequence, structureChanged: true,
                    budget: &legBudget
                ) {
                    accepted += 1
                } else if try runBatch(
                    // Tier 2: PRNG fallback (fresh bound content).
                    productSpaceBatchEncoder, decoder: prngDecoder,
                    targets: .wholeSequence, structureChanged: true,
                    budget: &legBudget
                ) {
                    accepted += 1
                }
            } else {
                // Adaptive: delta-debug coordinate halving for k > 3.
                productSpaceAdaptiveEncoder.bindIndex = bindSpanIndex
                while legBudget.isExhausted == false {
                    if try runAdaptive(
                        productSpaceAdaptiveEncoder, decoder: prngDecoder,
                        targets: .wholeSequence, structureChanged: true,
                        budget: &legBudget
                    ) {
                        accepted += 1
                    } else {
                        break
                    }
                }
            }

            // Fallback: run BindRootSearchEncoder for anything the product
            // space encoder didn't cover (non-converged axes, single-axis refinement).
            bindRootSearchEncoder.bindIndex = bindSpanIndex
            while legBudget.isExhausted == false {
                if try runAdaptive(
                    bindRootSearchEncoder,
                    decoder: prngDecoder,
                    targets: .wholeSequence,
                    structureChanged: true,
                    budget: &legBudget
                ) {
                    accepted += 1
                } else {
                    break
                }
            }
        }

        for slot in trainOrder {
            guard legBudget.isExhausted == false else { break }
            switch slot {
            case .zeroValue:
                let vSpans = spanCache.valueSpans(at: 0, from: sequence, bindIndex: bindIndex)
                if vSpans.isEmpty == false {
                    if try runAdaptive(zeroValueEncoder, decoder: trainDecoder, targets: .spans(vSpans), structureChanged: structureChangedOnCovariant, budget: &legBudget) {
                        accepted += 1
                        ReductionScheduler.moveToFront(.zeroValue, in: &trainOrder)
                    }
                }
            case .binarySearchToZero:
                let vSpans = spanCache.valueSpans(at: 0, from: sequence, bindIndex: bindIndex)
                if vSpans.isEmpty == false {
                    if try runAdaptive(binarySearchToZeroEncoder, decoder: trainDecoder, targets: .spans(vSpans), structureChanged: structureChangedOnCovariant, budget: &legBudget) {
                        accepted += 1
                        ReductionScheduler.moveToFront(.binarySearchToZero, in: &trainOrder)
                    }
                }
            case .binarySearchToTarget:
                let vSpans = spanCache.valueSpans(at: 0, from: sequence, bindIndex: bindIndex)
                if vSpans.isEmpty == false {
                    if try runAdaptive(binarySearchToTargetEncoder, decoder: trainDecoder, targets: .spans(vSpans), structureChanged: structureChangedOnCovariant, budget: &legBudget) {
                        accepted += 1
                        ReductionScheduler.moveToFront(.binarySearchToTarget, in: &trainOrder)
                    }
                }
            case .reduceFloat:
                let fSpans = spanCache.floatSpans(at: 0, from: sequence, bindIndex: bindIndex)
                if fSpans.isEmpty == false {
                    if try runAdaptive(reduceFloatEncoder, decoder: trainDecoder, targets: .spans(fSpans), structureChanged: structureChangedOnCovariant, budget: &legBudget) {
                        accepted += 1
                        ReductionScheduler.moveToFront(.reduceFloat, in: &trainOrder)
                    }
                }
            }
        }

        remaining -= legBudget.used
        return accepted
    }

    /// Runs a speculative exploration round: redistribute with regression allowed, then prune and train to exploit.
    ///
    /// Pipeline acceptance: final state must shortlex-precede the pre-exploration checkpoint. ``bestSequence`` and ``bestOutput`` only update if the full pipeline passes — intermediate results are discarded on rollback.
    func runExplorationLeg(remaining: inout Int) throws -> Bool {
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

        // Exploitation: run prune and train on the relaxed state.
        var exploitRemaining = remaining - explorationBudget.used
        let pruneAccepted = try runPruneLeg(remaining: &exploitRemaining, maxBindDepth: bindIndex?.maxBindDepth ?? 0)
        let trainAccepted = try runTrainLeg(remaining: &exploitRemaining)

        // Pipeline acceptance: final state must shortlex-precede checkpoint.
        if sequence.shortLexPrecedes(checkpointSequence) {
            bestSequence = sequence
            bestOutput = output
            remaining = exploitRemaining
            if isInstrumented {
                ExhaustLog.debug(category: .reducer, event: "exploration_accepted", metadata: [
                    "seq_len": "\(checkpointSequence.count)→\(sequence.count)",
                    "prune": "\(pruneAccepted)",
                    "train": "\(trainAccepted)",
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

    /// Runs redistribution encoders. Returns `true` if any redistribution was accepted.
    func runRedistributionLeg(remaining: inout Int) throws -> Bool {
        var legBudget = ReductionScheduler.LegBudget(hardCap: remaining)
        let redistContext = DecoderContext(depth: .global, bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .normal, useReductionMaterializer: config.useReductionMaterializer)
        let redistDecoder = SequenceDecoder.for(redistContext)
        var redistributionAccepted = false

        // Bind-aware redistribution: coordinate inner+bound across bind regions.
        if hasBind, let bi = bindIndex, bi.regions.count >= 2 {
            let regionPairs = RedistributeAcrossBindRegionsEncoder.buildPlans(
                from: sequence, bindIndex: bi
            )
            for plan in regionPairs {
                guard legBudget.isExhausted == false else { break }
                let sinkRegionIndex = plan.sink.regionIndex
                let bindRedistDecoder: SequenceDecoder = .guided(
                    fallbackTree: fallbackTree ?? tree,
                    maximizeBoundRegionIndices: Set([sinkRegionIndex])
                )
                bindAwareRedistributeEncoder.startPlan(
                    sequence: sequence, plan: plan
                )
                var lastAccepted = false
                while let probe = bindAwareRedistributeEncoder.nextProbe(lastAccepted: lastAccepted) {
                    guard legBudget.isExhausted == false else { break }
                    if let result = try bindRedistDecoder.decode(
                        candidate: probe, gen: gen, tree: tree,
                        originalSequence: sequence, property: property
                    ) {
                        legBudget.recordMaterialization()
                        accept(result, structureChanged: true)
                        lastAccepted = true
                        redistributionAccepted = true
                        if isInstrumented { ExhaustLog.debug(category: .reducer, event: "redistribution_accepted", metadata: ["encoder": "bindAwareRedistribute"]) }
                    } else {
                        legBudget.recordMaterialization()
                        lastAccepted = false
                    }
                }
            }
        }

        // Tandem reduction: reduce sibling value pairs together.
        let allSiblings = ChoiceSequence.extractSiblingGroups(from: sequence)
        if allSiblings.isEmpty == false {
            if try runAdaptive(tandemEncoder, decoder: redistDecoder, targets: .siblingGroups(allSiblings), structureChanged: hasBind, budget: &legBudget) {
                redistributionAccepted = true
                if isInstrumented { ExhaustLog.debug(category: .reducer, event: "redistribution_accepted", metadata: ["encoder": "tandemReduction"]) }
            }
        }

        // Cross-stage redistribution: move mass between coordinates.
        if try runAdaptive(redistributeEncoder, decoder: redistDecoder, targets: .wholeSequence, structureChanged: hasBind, budget: &legBudget) {
            redistributionAccepted = true
            if isInstrumented { ExhaustLog.debug(category: .reducer, event: "redistribution_accepted", metadata: ["encoder": redistributeEncoder.name.rawValue]) }
        }

        remaining -= legBudget.used
        return redistributionAccepted
    }
}
