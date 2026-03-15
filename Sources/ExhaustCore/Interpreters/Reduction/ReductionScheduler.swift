/// Bonsai cultivation cycle scheduler for principled test case reduction.
///
/// Orchestrates encoders and decoders in the cultivation cycle: snip (contravariant sweep, depths max→1, exact), prune (deletion sweep, depths 0→max, guided), train (covariant sweep, depth 0, guided for binds), and shape (redistribution).
///
/// Resource tracking uses per-leg budgets with unused-budget forwarding. Each leg has a hard cap (maximum materializations) and a stall patience (maximum consecutive fruitless materializations). Forwarded budget extends productive legs but does not increase patience for unproductive ones.
///
/// Encoder ordering within each leg uses move-to-front: when an encoder succeeds, it is promoted to the front of its leg's order for subsequent iterations. This adapts to generator structure without parameters — productive encoders are tried first, reducing wasted materializations on consistently fruitless encoders.
enum ReductionScheduler {
    // MARK: - Encoder Ordering

    /// Value minimization and reordering encoder slots, used by the snip and train legs.
    enum ValueEncoderSlot: CaseIterable {
        case zeroValue
        case binarySearchToZero
        case binarySearchToTarget
        case reduceFloat
        case reorderSiblings
    }

    /// Deletion encoder slots, used by the prune leg.
    enum DeletionEncoderSlot: CaseIterable {
        case containerSpans
        case sequenceElements
        case sequenceBoundaries
        case freeStandingValues
        case alignedWindows
        case speculativeDelete

        var spanCategory: DeletionSpanCategory {
            switch self {
            case .containerSpans: .containerSpans
            case .sequenceElements: .sequenceElements
            case .sequenceBoundaries: .sequenceBoundaries
            case .freeStandingValues: .freeStandingValues
            case .alignedWindows: .containerSpans
            case .speculativeDelete: .mixed
            }
        }
    }

    /// Promotes `slot` to the front of `order`. No-op if already at front.
    static func moveToFront<Slot: Equatable>(_ slot: Slot, in order: inout [Slot]) {
        guard let index = order.firstIndex(of: slot), index > 0 else { return }
        order.remove(at: index)
        order.insert(slot, at: 0)
    }

    // MARK: - Leg Budget Tracker

    /// Tracks materialization budget within a single V-cycle leg.
    ///
    /// Two counters: `used` (total materializations, capped by `hardCap`) and `consecutiveFruitless` (consecutive failures, capped by `stallPatience`). A success resets the fruitless counter.
    struct LegBudget {
        /// Maximum total materializations this leg may consume.
        let hardCap: Int
        /// Maximum consecutive fruitless materializations before the leg gives up.
        let stallPatience: Int

        private(set) var used = 0
        private(set) var consecutiveFruitless = 0

        var isExhausted: Bool {
            used >= hardCap || consecutiveFruitless >= stallPatience
        }

        mutating func recordMaterialization(accepted: Bool) {
            used += 1
            if accepted {
                consecutiveFruitless = 0
            } else {
                consecutiveFruitless += 1
            }
        }
    }

    // MARK: - Default cycle budget

    /// Default per-cycle materialization budget.
    ///
    /// Sized to allow thorough reduction for typical generators. The per-leg weights distribute this across the V-cycle legs.
    static let defaultCycleBudgetTotal = 300

    // MARK: - Entry Point

    /// Runs the V-cycle reduction to a fixed point or budget exhaustion.
    static func run<Output>(
        gen: ReflectiveGenerator<Output>,
        initialTree: ChoiceTree,
        config: Interpreters.BonsaiReducerConfiguration,
        property: (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        let isInstrumented = ExhaustLog.isEnabled(.debug, for: .reducer)

        var sequence = ChoiceSequence.flatten(initialTree)
        var tree = initialTree
        guard var output = try Interpreters.materialize(gen, with: tree, using: sequence) else {
            return nil
        }

        let hasBind = initialTree.containsBind
        var bindIndex: BindSpanIndex? = hasBind ? BindSpanIndex(from: sequence) : nil
        var fallbackTree: ChoiceTree? = hasBind ? tree : nil
        var bestSequence = sequence
        var bestOutput = output
        var rejectCache = ReducerCache()
        var spanCache = SpanCache()
        var stallBudget = config.maxStalls
        var cyclesSinceRedistribution = 0
        let redistributionDeferralCap = 3
        var cycles = 0

        let cycleBudget = CycleBudget(total: defaultCycleBudgetTotal, legWeights: CycleBudget.defaultWeights())

        // Build encoders.
        var promoteBranchesEncoder = PromoteBranchesEncoder()
        var pivotBranchesEncoder = PivotBranchesEncoder()
        var deleteContainerSpans = DeleteContainerSpansEncoder()
        var deleteSequenceElements = DeleteSequenceElementsEncoder()
        var deleteSequenceBoundaries = DeleteSequenceBoundariesEncoder()
        var deleteFreeStandingValues = DeleteFreeStandingValuesEncoder()
        var speculativeDelete = SpeculativeDeleteEncoder()
        var zeroValueEncoder = ZeroValueEncoder()
        var binarySearchToZeroEncoder = BinarySearchToZeroEncoder()
        var binarySearchToTargetEncoder = BinarySearchToTargetEncoder()
        let reorderEncoder = ReorderSiblingsEncoder()

        var reduceFloatEncoder = ReduceFloatEncoder()
        var deleteAlignedWindowsEncoder = DeleteAlignedWindowsEncoder(
            beamTuning: config.alignedDeletionBeamSearchTuning
        )
        var tandemEncoder = TandemReductionEncoder()
        var redistributeEncoder = CrossStageRedistributeEncoder()
        var bindAwareRedistributeEncoder = BindAwareRedistributeEncoder()
        var lattice = DominanceLattice()

        // Encoder ordering: move-to-front per leg, persists across cycles.
        var snipOrder: [ValueEncoderSlot] = ValueEncoderSlot.allCases
        var pruneOrder: [DeletionEncoderSlot] = DeletionEncoderSlot.allCases
        var trainOrder: [ValueEncoderSlot] = ValueEncoderSlot.allCases

        // MARK: - Helpers

        func accept(_ result: ShrinkResult<Output>, structureChanged: Bool) {
            sequence = result.sequence
            tree = result.tree
            output = result.output
            fallbackTree = result.tree
            // Invalidate cached spans — structure changed means indices shifted;
            // even value-only changes invalidate value span targets.
            spanCache.invalidate()
            if structureChanged {
                bindIndex = hasBind ? BindSpanIndex(from: sequence) : nil
                if config.useReductionMaterializer == false {
                    // Legacy path: re-derive a consistent (sequence, tree) pair after
                    // structural changes. Decoders like .direct return the original tree,
                    // which becomes stale after deletion. GuidedMaterializer replays the
                    // accepted sequence as prefix and rebuilds a matching tree.
                    //
                    // Not needed for ReductionMaterializer — the fresh decoder results
                    // already have a current tree with fresh validRange metadata.
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
            _ encoder: any BatchEncoder,
            decoder: SequenceDecoder,
            targets: TargetSet,
            structureChanged: Bool,
            cache: inout ReducerCache,
            budget: inout LegBudget
        ) throws -> Bool {
            guard budget.isExhausted == false else { return false }
            if lattice.shouldSkip(encoder.name, phase: encoder.phase) { return false }
            let startSeqLen = sequence.count
            var probes = 0
            for candidate in encoder.encode(sequence: sequence, targets: targets) {
                guard budget.isExhausted == false else { break }
                guard cache.contains(candidate) == false else { continue }
                probes += 1
                if let result = try decoder.decode(
                    candidate: candidate,
                    gen: gen,
                    tree: tree,
                    originalSequence: sequence,
                    property: property
                ) {
                    budget.recordMaterialization(accepted: true)
                    accept(result, structureChanged: structureChanged)
                    // Don't record lattice success for batch encoders:
                    // runBatch stops at the first success (angelic resolution),
                    // so the encoder didn't cover all targets. The 2-cell
                    // dominance (paper Def 15.3) is sound only when the
                    // dominator runs to exhaustion — skipping a dominated
                    // encoder after partial dominator execution is unsound.
                    if isInstrumented {
                        ExhaustLog.debug(category: .reducer, event: "encoder_accepted", metadata: [
                            "encoder": encoder.name, "probes": "\(probes)",
                            "seq_len": "\(startSeqLen)→\(sequence.count)",
                            "output": "\(output)",
                        ])
                    }
                    return true
                }
                budget.recordMaterialization(accepted: false)
                cache.insert(candidate)
            }
            if isInstrumented {
                if probes > 0 {
                    ExhaustLog.debug(category: .reducer, event: "encoder_exhausted", metadata: [
                        "encoder": encoder.name, "probes": "\(probes)",
                        "seq_len": "\(startSeqLen)",
                    ])
                } else {
                    ExhaustLog.debug(category: .reducer, event: "encoder_no_probes", metadata: [
                        "encoder": encoder.name,
                    ])
                }
            }
            return false
        }

        /// Runs an adaptive encoder against a decoder, tracking materializations. Returns true if any probe was accepted.
        func runAdaptive(
            _ encoder: inout some AdaptiveEncoder,
            decoder: SequenceDecoder,
            targets: TargetSet,
            structureChanged: Bool,
            cache _: inout ReducerCache,
            budget: inout LegBudget
        ) throws -> Bool {
            guard budget.isExhausted == false else { return false }
            if lattice.shouldSkip(encoder.name, phase: encoder.phase) { return false }
            let startSeqLen = sequence.count
            encoder.start(sequence: sequence, targets: targets)
            var lastAccepted = false
            var anyAccepted = false
            var probes = 0
            var accepted = 0
            while let probe = encoder.nextProbe(lastAccepted: lastAccepted) {
                guard budget.isExhausted == false else { break }
                probes += 1
                if let result = try decoder.decode(
                    candidate: probe, gen: gen, tree: tree,
                    originalSequence: sequence, property: property
                ) {
                    budget.recordMaterialization(accepted: true)
                    accept(result, structureChanged: structureChanged)
                    lastAccepted = true
                    anyAccepted = true
                    accepted += 1
                } else {
                    budget.recordMaterialization(accepted: false)
                    lastAccepted = false
                }
            }
            if anyAccepted {
                lattice.recordSuccess(encoder.name)
            }
            if isInstrumented {
                if probes > 0 {
                    ExhaustLog.debug(category: .reducer, event: anyAccepted ? "encoder_accepted" : "encoder_exhausted", metadata: [
                        "encoder": encoder.name, "probes": "\(probes)", "accepted": "\(accepted)",
                        "seq_len": "\(startSeqLen)→\(sequence.count)",
                        "output": anyAccepted ? "\(output)" : "",
                    ])
                } else {
                    ExhaustLog.debug(category: .reducer, event: "encoder_no_probes", metadata: [
                        "encoder": encoder.name,
                    ])
                }
            }
            return anyAccepted
        }

        func makeDeletionDecoder(at depth: Int) -> SequenceDecoder {
            let context = DecoderContext(depth: .specific(depth), bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .relaxed, useReductionMaterializer: config.useReductionMaterializer)
            return SequenceDecoder.for(context)
        }

        func makeDepthZeroDecoder() -> SequenceDecoder {
            let context = DecoderContext(depth: .specific(0), bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .normal, useReductionMaterializer: config.useReductionMaterializer)
            return SequenceDecoder.for(context)
        }

        // MARK: - V-Cycle

        while stallBudget > 0 {
            cycles += 1
            let cycleStartBest = bestSequence
            var cycleImproved = false
            let maxBindDepth = bindIndex?.maxBindDepth ?? 0
            var contravariantAccepted = 0
            var deletionAccepted = 0
            var covariantAccepted = 0
            var dirtyDepths = Set(0 ... maxBindDepth)

            // Per-cycle budget with unused-budget forwarding.
            var remaining = cycleBudget.total

            // ── Cost-based encoder ordering ──
            // Compute costs once per slot, cache in dictionaries, then sort.
            // Eliminates O(n log n) repeated estimatedCost calls in sort comparators.
            do {
                var valueCosts = [ValueEncoderSlot: Int]()
                for slot in ValueEncoderSlot.allCases {
                    let cost: Int? = switch slot {
                    case .zeroValue: zeroValueEncoder.estimatedCost(sequence: sequence, bindIndex: bindIndex)
                    case .binarySearchToZero: binarySearchToZeroEncoder.estimatedCost(sequence: sequence, bindIndex: bindIndex)
                    case .binarySearchToTarget: binarySearchToTargetEncoder.estimatedCost(sequence: sequence, bindIndex: bindIndex)
                    case .reduceFloat: reduceFloatEncoder.estimatedCost(sequence: sequence, bindIndex: bindIndex)
                    case .reorderSiblings: reorderEncoder.estimatedCost(sequence: sequence, bindIndex: bindIndex)
                    }
                    if let cost { valueCosts[slot] = cost }
                }

                var deletionCosts = [DeletionEncoderSlot: Int]()
                for slot in DeletionEncoderSlot.allCases {
                    let cost: Int? = switch slot {
                    case .containerSpans: deleteContainerSpans.estimatedCost(sequence: sequence, bindIndex: bindIndex)
                    case .sequenceElements: deleteSequenceElements.estimatedCost(sequence: sequence, bindIndex: bindIndex)
                    case .sequenceBoundaries: deleteSequenceBoundaries.estimatedCost(sequence: sequence, bindIndex: bindIndex)
                    case .freeStandingValues: deleteFreeStandingValues.estimatedCost(sequence: sequence, bindIndex: bindIndex)
                    case .alignedWindows: deleteAlignedWindowsEncoder.estimatedCost(sequence: sequence, bindIndex: bindIndex)
                    case .speculativeDelete: speculativeDelete.estimatedCost(sequence: sequence, bindIndex: bindIndex)
                    }
                    if let cost { deletionCosts[slot] = cost }
                }

                snipOrder = ValueEncoderSlot.allCases
                    .filter { valueCosts[$0] != nil }
                    .sorted { (valueCosts[$0] ?? 0) < (valueCosts[$1] ?? 0) }

                // trainOrder starts identical to snipOrder; move-to-front diverges during cycle.
                trainOrder = snipOrder

                pruneOrder = DeletionEncoderSlot.allCases
                    .filter { deletionCosts[$0] != nil }
                    .sorted { (deletionCosts[$0] ?? 0) < (deletionCosts[$1] ?? 0) }
            }

            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "vcycle_start",
                    metadata: ["cycle": "\(cycles)", "stall_budget": "\(stallBudget)", "max_bind_depth": "\(maxBindDepth)", "cycle_budget": "\(remaining)"]
                )
            }

            // ── Pre-cycle: Branch tactics ──
            // Branch encoders use the standard runBatch flow. The
            // ReductionMaterializer produces fresh trees with all branch
            // alternatives, so no post-branch re-derivation is needed.
            do {
                let branchDecoder = makeDeletionDecoder(at: 0)
                var branchBudget = LegBudget(hardCap: remaining, stallPatience: remaining)

                promoteBranchesEncoder.currentTree = tree
                if try runBatch(promoteBranchesEncoder, decoder: branchDecoder, targets: .wholeSequence, structureChanged: true, cache: &rejectCache, budget: &branchBudget) {
                    cycleImproved = true
                }

                pivotBranchesEncoder.currentTree = tree
                if try runBatch(pivotBranchesEncoder, decoder: branchDecoder, targets: .wholeSequence, structureChanged: true, cache: &rejectCache, budget: &branchBudget) {
                    cycleImproved = true
                }

                remaining -= branchBudget.used
            }

            // ── Leg 1: Snip — contravariant sweep (depths max → 1) ──
            do {
                let target = cycleBudget.initialBudget(for: .contravariant)
                var legBudget = LegBudget(hardCap: remaining, stallPatience: target)
                rejectCache = ReducerCache()
                spanCache.invalidate()
                lattice.invalidate()
                if maxBindDepth >= 1 {
                    for depth in stride(from: maxBindDepth, through: 1, by: -1) where dirtyDepths.contains(depth) {
                        guard legBudget.isExhausted == false else { break }
                        var depthProgress = true
                        while depthProgress, legBudget.isExhausted == false {
                            depthProgress = false
                            let context = DecoderContext(depth: .specific(depth), bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .normal, useReductionMaterializer: config.useReductionMaterializer)
                            let decoder = SequenceDecoder.for(context)
                            let vSpans = spanCache.valueSpans(at: depth, from: sequence, bindIndex: bindIndex)
                            let fSpans = spanCache.floatSpans(at: depth, from: sequence, bindIndex: bindIndex)
                            let sGroups = spanCache.siblingGroups(at: depth, from: sequence, bindIndex: bindIndex)

                            for slot in snipOrder {
                                guard legBudget.isExhausted == false else { break }
                                switch slot {
                                case .zeroValue:
                                    if vSpans.isEmpty == false {
                                        if try runAdaptive(&zeroValueEncoder, decoder: decoder, targets: .spans(vSpans), structureChanged: false, cache: &rejectCache, budget: &legBudget) {
                                            depthProgress = true
                                            contravariantAccepted += 1
                                            Self.moveToFront(.zeroValue, in: &snipOrder)
                                        }
                                    }
                                case .binarySearchToZero:
                                    if vSpans.isEmpty == false {
                                        if try runAdaptive(&binarySearchToZeroEncoder, decoder: decoder, targets: .spans(vSpans), structureChanged: false, cache: &rejectCache, budget: &legBudget) {
                                            depthProgress = true
                                            contravariantAccepted += 1
                                            Self.moveToFront(.binarySearchToZero, in: &snipOrder)
                                        }
                                    }
                                case .binarySearchToTarget:
                                    if vSpans.isEmpty == false {
                                        if try runAdaptive(&binarySearchToTargetEncoder, decoder: decoder, targets: .spans(vSpans), structureChanged: false, cache: &rejectCache, budget: &legBudget) {
                                            depthProgress = true
                                            contravariantAccepted += 1
                                            Self.moveToFront(.binarySearchToTarget, in: &snipOrder)
                                        }
                                    }
                                case .reduceFloat:
                                    if fSpans.isEmpty == false {
                                        if try runAdaptive(&reduceFloatEncoder, decoder: decoder, targets: .spans(fSpans), structureChanged: false, cache: &rejectCache, budget: &legBudget) {
                                            depthProgress = true
                                            contravariantAccepted += 1
                                            Self.moveToFront(.reduceFloat, in: &snipOrder)
                                        }
                                    }
                                case .reorderSiblings:
                                    if sGroups.isEmpty == false {
                                        if try runBatch(reorderEncoder, decoder: decoder, targets: .siblingGroups(sGroups), structureChanged: false, cache: &rejectCache, budget: &legBudget) {
                                            depthProgress = true
                                            contravariantAccepted += 1
                                            Self.moveToFront(.reorderSiblings, in: &snipOrder)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                remaining -= legBudget.used
            }

            // ── Leg 2: Prune — deletion sweep (depths 0 → max) ──
            do {
                let target = cycleBudget.initialBudget(for: .deletion)
                var legBudget = LegBudget(hardCap: remaining, stallPatience: target)
                rejectCache = ReducerCache()
                spanCache.invalidate()
                lattice.invalidate()
                for depth in 0 ... maxBindDepth {
                    guard legBudget.isExhausted == false else { break }

                    // Decoder context depends on depth, bind index, and strictness — all
                    // stable within a depth iteration. Create once per depth, reuse across slots.
                    let depthDecoder = makeDeletionDecoder(at: depth)

                    for slot in pruneOrder {
                        guard legBudget.isExhausted == false else { break }
                        // Targets are re-extracted per slot via SpanCache (invalidated by
                        // accept(structureChanged: true) between encoder calls).
                        let accepted: Bool = switch slot {
                        case .containerSpans:
                            try runAdaptive(&deleteContainerSpans, decoder: depthDecoder, targets: .spans(spanCache.deletionTargets(category: slot.spanCategory, depth: depth, from: sequence, bindIndex: bindIndex)), structureChanged: true, cache: &rejectCache, budget: &legBudget)
                        case .sequenceElements:
                            try runAdaptive(&deleteSequenceElements, decoder: depthDecoder, targets: .spans(spanCache.deletionTargets(category: slot.spanCategory, depth: depth, from: sequence, bindIndex: bindIndex)), structureChanged: true, cache: &rejectCache, budget: &legBudget)
                        case .sequenceBoundaries:
                            try runAdaptive(&deleteSequenceBoundaries, decoder: depthDecoder, targets: .spans(spanCache.deletionTargets(category: slot.spanCategory, depth: depth, from: sequence, bindIndex: bindIndex)), structureChanged: true, cache: &rejectCache, budget: &legBudget)
                        case .freeStandingValues:
                            try runAdaptive(&deleteFreeStandingValues, decoder: depthDecoder, targets: .spans(spanCache.deletionTargets(category: slot.spanCategory, depth: depth, from: sequence, bindIndex: bindIndex)), structureChanged: true, cache: &rejectCache, budget: &legBudget)
                        case .alignedWindows:
                            try runAdaptive(&deleteAlignedWindowsEncoder, decoder: depthDecoder, targets: .spans(spanCache.deletionTargets(category: slot.spanCategory, depth: depth, from: sequence, bindIndex: bindIndex)), structureChanged: true, cache: &rejectCache, budget: &legBudget)
                        case .speculativeDelete:
                            try runAdaptive(&speculativeDelete, decoder: depthDecoder, targets: .spans(spanCache.deletionTargets(category: slot.spanCategory, depth: depth, from: sequence, bindIndex: bindIndex)), structureChanged: true, cache: &rejectCache, budget: &legBudget)
                        }
                        if accepted {
                            deletionAccepted += 1
                            cycleImproved = true
                            Self.moveToFront(slot, in: &pruneOrder)
                        }
                    }
                }
                remaining -= legBudget.used
                if deletionAccepted > 0 {
                    dirtyDepths = Set(0 ... (bindIndex?.maxBindDepth ?? 0))
                }
            }

            // ── Leg 3: Train — covariant sweep (depth 0) ──
            do {
                let target = cycleBudget.initialBudget(for: .covariant)
                var legBudget = LegBudget(hardCap: remaining, stallPatience: target)
                rejectCache = ReducerCache()
                spanCache.invalidate()
                lattice.invalidate()
                // ReductionMaterializer produces fresh trees with current validRange
                // on every materialization, so no separate re-derivation is needed
                // for range refreshes. Pass structureChanged to accept() for bind
                // index refresh when binds are present.
                let structureChangedOnCovariant = hasBind

                // Decoder context depends on depth (0), bind index, and strictness — all
                // stable within the Train leg. Create once, reuse across all slots.
                let trainDecoder = makeDepthZeroDecoder()

                // Targets are re-extracted per slot via SpanCache (invalidated by
                // accept() between encoder calls).
                for slot in trainOrder {
                    guard legBudget.isExhausted == false else { break }
                    switch slot {
                    case .zeroValue:
                        let vSpans = spanCache.valueSpans(at: 0, from: sequence, bindIndex: bindIndex)
                        if vSpans.isEmpty == false {
                            if try runAdaptive(&zeroValueEncoder, decoder: trainDecoder, targets: .spans(vSpans), structureChanged: structureChangedOnCovariant, cache: &rejectCache, budget: &legBudget) {
                                covariantAccepted += 1
                                cycleImproved = true
                                Self.moveToFront(.zeroValue, in: &trainOrder)
                            }
                        }
                    case .binarySearchToZero:
                        let vSpans = spanCache.valueSpans(at: 0, from: sequence, bindIndex: bindIndex)
                        if vSpans.isEmpty == false {
                            if try runAdaptive(&binarySearchToZeroEncoder, decoder: trainDecoder, targets: .spans(vSpans), structureChanged: structureChangedOnCovariant, cache: &rejectCache, budget: &legBudget) {
                                covariantAccepted += 1
                                cycleImproved = true
                                Self.moveToFront(.binarySearchToZero, in: &trainOrder)
                            }
                        }
                    case .binarySearchToTarget:
                        let vSpans = spanCache.valueSpans(at: 0, from: sequence, bindIndex: bindIndex)
                        if vSpans.isEmpty == false {
                            if try runAdaptive(&binarySearchToTargetEncoder, decoder: trainDecoder, targets: .spans(vSpans), structureChanged: structureChangedOnCovariant, cache: &rejectCache, budget: &legBudget) {
                                covariantAccepted += 1
                                cycleImproved = true
                                Self.moveToFront(.binarySearchToTarget, in: &trainOrder)
                            }
                        }
                    case .reduceFloat:
                        let fSpans = spanCache.floatSpans(at: 0, from: sequence, bindIndex: bindIndex)
                        if fSpans.isEmpty == false {
                            if try runAdaptive(&reduceFloatEncoder, decoder: trainDecoder, targets: .spans(fSpans), structureChanged: structureChangedOnCovariant, cache: &rejectCache, budget: &legBudget) {
                                covariantAccepted += 1
                                cycleImproved = true
                                Self.moveToFront(.reduceFloat, in: &trainOrder)
                            }
                        }
                    case .reorderSiblings:
                        let sGroups = spanCache.siblingGroups(at: 0, from: sequence, bindIndex: bindIndex)
                        if sGroups.isEmpty == false {
                            if try runBatch(reorderEncoder, decoder: trainDecoder, targets: .siblingGroups(sGroups), structureChanged: structureChangedOnCovariant, cache: &rejectCache, budget: &legBudget) {
                                covariantAccepted += 1
                                cycleImproved = true
                                Self.moveToFront(.reorderSiblings, in: &trainOrder)
                            }
                        }
                    }
                }

                remaining -= legBudget.used
                if covariantAccepted > 0 {
                    dirtyDepths = Set(0 ... (bindIndex?.maxBindDepth ?? 0))
                }
            }

            // ── Cross-cutting: Redistribution ──
            let redistributionTriggered =
                (contravariantAccepted == 0 && deletionAccepted == 0)
                    || cyclesSinceRedistribution >= redistributionDeferralCap

            if redistributionTriggered {
                cyclesSinceRedistribution = 0
                let target = cycleBudget.initialBudget(for: .redistribution)
                var legBudget = LegBudget(hardCap: remaining, stallPatience: target)
                let redistContext = DecoderContext(depth: .global, bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .normal, useReductionMaterializer: config.useReductionMaterializer)
                let redistDecoder = SequenceDecoder.for(redistContext)
                var redistributionAccepted = false

                // Bind-aware redistribution: coordinate inner+bound across bind regions.
                // Runs first because it's the most targeted for bind-coupled generators,
                // where the cross-stage encoder cannot make progress.
                if hasBind, let bi = bindIndex, bi.regions.count >= 2 {
                    let regionPairs = BindAwareRedistributeEncoder.buildPlans(
                        from: sequence, bindIndex: bi
                    )
                    for plan in regionPairs {
                        guard legBudget.isExhausted == false else { break }
                        let sinkRegionIndex = plan.sink.regionIndex
                        let bindRedistDecoder: SequenceDecoder = .guidedFresh(
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
                                legBudget.recordMaterialization(accepted: true)
                                accept(result, structureChanged: true)
                                lastAccepted = true
                                cycleImproved = true
                                redistributionAccepted = true
                                if isInstrumented { ExhaustLog.debug(category: .reducer, event: "redistribution_accepted", metadata: ["encoder": "bindAwareRedistribute"]) }
                            } else {
                                legBudget.recordMaterialization(accepted: false)
                                lastAccepted = false
                            }
                        }
                    }
                }

                // Tandem reduction: reduce sibling value pairs together.
                let allSiblings = ChoiceSequence.extractSiblingGroups(from: sequence)
                if allSiblings.isEmpty == false {
                    if try runAdaptive(&tandemEncoder, decoder: redistDecoder, targets: .siblingGroups(allSiblings), structureChanged: hasBind, cache: &rejectCache, budget: &legBudget) {
                        cycleImproved = true
                        redistributionAccepted = true
                        if isInstrumented { ExhaustLog.debug(category: .reducer, event: "redistribution_accepted", metadata: ["encoder": "tandemReduction"]) }
                    }
                }

                // Cross-stage redistribution: move mass between coordinates.
                if try runAdaptive(&redistributeEncoder, decoder: redistDecoder, targets: .wholeSequence, structureChanged: hasBind, cache: &rejectCache, budget: &legBudget) {
                    cycleImproved = true
                    redistributionAccepted = true
                    if isInstrumented { ExhaustLog.debug(category: .reducer, event: "redistribution_accepted", metadata: ["encoder": "crossStageRedistribute"]) }
                }

                if redistributionAccepted {
                    dirtyDepths = Set(0 ... (bindIndex?.maxBindDepth ?? 0))
                }
            } else {
                cyclesSinceRedistribution += 1
            }

            // ── Cycle termination ──
            // A cycle counts as improved only if the global best advanced.
            // Encoders that re-discover the same values (cross-zero probes on already-optimal
            // values, tandem oscillation) would otherwise reset the stall budget forever.
            if bestSequence.count < cycleStartBest.count || bestSequence.shortLexPrecedes(cycleStartBest) {
                stallBudget = config.maxStalls
            } else {
                stallBudget -= 1
            }
        }

        if isInstrumented {
            ExhaustLog.notice(category: .reducer, event: "vcycle_complete", metadata: ["cycles": "\(cycles)"])
        }

        return (bestSequence, bestOutput)
    }
}
