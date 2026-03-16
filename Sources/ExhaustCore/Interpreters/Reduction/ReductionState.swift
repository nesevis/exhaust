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

    // Encoders
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
    var deleteAlignedWindowsEncoder: DeleteAlignedWindowsEncoder
    var tandemEncoder = TandemReductionEncoder()
    var redistributeEncoder = CrossStageRedistributeEncoder()
    var bindAwareRedistributeEncoder = BindAwareRedistributeEncoder()

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
        _ encoder: any BatchEncoder,
        decoder: SequenceDecoder,
        targets: TargetSet,
        structureChanged: Bool,
        budget: inout ReductionScheduler.LegBudget
    ) throws -> Bool {
        guard budget.isExhausted == false else { return false }
        if lattice.shouldSkip(encoder.name, phase: encoder.phase) { return false }
        let startSeqLen = sequence.count
        var probes = 0
        for candidate in encoder.encode(sequence: sequence, targets: targets) {
            guard budget.isExhausted == false else { break }
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
        _ encoder: some AdaptiveEncoder,
        decoder: SequenceDecoder,
        targets: TargetSet,
        structureChanged: Bool,
        budget: inout ReductionScheduler.LegBudget
    ) throws -> Bool {
        guard budget.isExhausted == false else { return false }
        if lattice.shouldSkip(encoder.name, phase: encoder.phase) { return false }
        let startSeqLen = sequence.count
        var encoder = encoder
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
            case .reorderSiblings: reorderEncoder.estimatedCost(sequence: sequence, bindIndex: bindIndex)
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
            case .speculativeDelete: speculativeDelete.estimatedCost(sequence: sequence, bindIndex: bindIndex)
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
        let branchDecoder = makeDeletionDecoder(at: 0)
        var branchBudget = ReductionScheduler.LegBudget(hardCap: remaining, stallPatience: remaining)
        var improved = false

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
        var legBudget = ReductionScheduler.LegBudget(hardCap: remaining, stallPatience: target)
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
                    let sGroups = spanCache.siblingGroups(at: depth, from: sequence, bindIndex: bindIndex)

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
                        case .reorderSiblings:
                            if sGroups.isEmpty == false {
                                if try runBatch(reorderEncoder, decoder: decoder, targets: .siblingGroups(sGroups), structureChanged: false, budget: &legBudget) {
                                    depthProgress = true
                                    accepted += 1
                                    ReductionScheduler.moveToFront(.reorderSiblings, in: &snipOrder)
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
        var legBudget = ReductionScheduler.LegBudget(hardCap: remaining, stallPatience: target)
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
                case .speculativeDelete:
                    try runAdaptive(speculativeDelete, decoder: depthDecoder, targets: .spans(spanCache.deletionTargets(category: slot.spanCategory, depth: depth, from: sequence, bindIndex: bindIndex)), structureChanged: true, budget: &legBudget)
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
        var legBudget = ReductionScheduler.LegBudget(hardCap: remaining, stallPatience: target)
        spanCache.invalidate()
        lattice.invalidate()
        let structureChangedOnCovariant = hasBind
        let trainDecoder = makeDepthZeroDecoder()
        var accepted = 0

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
            case .reorderSiblings:
                let sGroups = spanCache.siblingGroups(at: 0, from: sequence, bindIndex: bindIndex)
                if sGroups.isEmpty == false {
                    if try runBatch(reorderEncoder, decoder: trainDecoder, targets: .siblingGroups(sGroups), structureChanged: structureChangedOnCovariant, budget: &legBudget) {
                        accepted += 1
                        ReductionScheduler.moveToFront(.reorderSiblings, in: &trainOrder)
                    }
                }
            }
        }

        remaining -= legBudget.used
        return accepted
    }

    /// Runs redistribution encoders. Returns `true` if any redistribution was accepted.
    func runRedistributionLeg(remaining: inout Int) throws -> Bool {
        let target = cycleBudget.initialBudget(for: .redistribution)
        var legBudget = ReductionScheduler.LegBudget(hardCap: remaining, stallPatience: target)
        let redistContext = DecoderContext(depth: .global, bindIndex: bindIndex, fallbackTree: fallbackTree, strictness: .normal, useReductionMaterializer: config.useReductionMaterializer)
        let redistDecoder = SequenceDecoder.for(redistContext)
        var redistributionAccepted = false

        // Bind-aware redistribution: coordinate inner+bound across bind regions.
        if hasBind, let bi = bindIndex, bi.regions.count >= 2 {
            let regionPairs = BindAwareRedistributeEncoder.buildPlans(
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
                        legBudget.recordMaterialization(accepted: true)
                        accept(result, structureChanged: true)
                        lastAccepted = true
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
            if try runAdaptive(tandemEncoder, decoder: redistDecoder, targets: .siblingGroups(allSiblings), structureChanged: hasBind, budget: &legBudget) {
                redistributionAccepted = true
                if isInstrumented { ExhaustLog.debug(category: .reducer, event: "redistribution_accepted", metadata: ["encoder": "tandemReduction"]) }
            }
        }

        // Cross-stage redistribution: move mass between coordinates.
        if try runAdaptive(redistributeEncoder, decoder: redistDecoder, targets: .wholeSequence, structureChanged: hasBind, budget: &legBudget) {
            redistributionAccepted = true
            if isInstrumented { ExhaustLog.debug(category: .reducer, event: "redistribution_accepted", metadata: ["encoder": "crossStageRedistribute"]) }
        }

        remaining -= legBudget.used
        return redistributionAccepted
    }
}
