//
//  ReductionMachine.swift
//  Exhaust
//

// MARK: - Reduction Machine

/// Drives graph-based reduction as an explicit state machine.
///
/// Each call to ``next()`` performs one logical unit of work and returns a ``Transition`` describing what happened. The caller iterates until `nil`:
///
/// ```swift
/// var machine = ReductionMachine(...)
/// while let transition = try machine.next() {
///     machine.stats.recordTiming(transition, elapsed: ...)
/// }
/// ```
///
/// ## Phases
///
/// The machine cycles through seven top-level phases:
///
/// ```
/// beginCycle → dispatching ⟳ → endCycle → postCycle → checkTermination
///            → beginCycle | reorderPass → done
/// ```
///
/// The ``dispatching`` phase uses four sub-phases (``DispatchPhase``) that decompose the probe loop into individual steps: evaluate a source, encode a candidate, decode it against the property, and optionally rebuild the graph.
package struct ReductionMachine {

    // MARK: - Phase

    /// Tracks which stage of the reduction pipeline the machine is in. The outer loop cycles through ``beginCycle`` → ``dispatching`` → ``endCycle`` → ``postCycle`` → ``checkTermination``, exiting via ``reorderPass`` → ``done`` when the stall budget is exhausted or all values converge.
    enum Phase {
        case beginCycle
        case dispatching
        case endCycle
        case postCycle(remaining: [ChoiceGraphScheduler.PostCycleAction])
        case checkTermination
        case reorderPass
        case done
    }

    /// Tracks where the machine is within a single ``Phase/dispatching`` step. Each call to ``next()`` during dispatching advances through one sub-phase: selecting a source (``dispatch``), producing a candidate (``encode``), materializing and checking the property (``decode``), flushing encoder state (``finishEncoder``), or rebuilding the graph after a structural acceptance (``rebuild``).
    enum DispatchPhase {
        case dispatch
        case encode
        case decode
        case finishEncoder
        case rebuild
    }

    // MARK: - Transition

    /// Reports what happened during the ``dispatch`` sub-phase of a single ``next()`` call.
    package enum DispatchOutcome {
        /// No source had a remaining transformation, or the pulled source was exhausted.
        case sourceExhausted
        /// The transformation was skipped by the dispatch decision (invalid scope, cached rejection, or gate skip).
        case skipped
        /// The graph was stripped (picks not materialized) and needed rematerialization before a path-changing operation.
        case rematerialized
        /// An encoder was selected, started, and is ready to produce probes.
        case encoderStarted(encoder: EncoderName)
    }

    /// Describes the single unit of work performed by one call to ``next()``. Returned to the caller for logging and per-step timing aggregation via ``ReductionStats/StepTimings/record(_:elapsed:)``.
    package enum Transition {
        case cycleStarted(cycle: Int, sourceCount: Int, sequenceLength: Int)
        case cycleEnded(stallBudget: Int)

        case dispatched(decision: DispatchOutcome)
        case encoded(encoder: EncoderName, cacheHit: Bool)
        case decoded(encoder: EncoderName, accepted: Bool)
        case rebuilt(sequenceLength: Int, structurallyChanged: Bool)

        case convergenceConfirmed(anyStale: Bool)
        case relaxRoundCompleted(improved: Bool)
        case deferralReleased

        case reorderCompleted(accepted: Bool)
        case terminated
    }

    // MARK: - State

    var phase: Phase = .beginCycle
    var dispatchPhase: DispatchPhase = .dispatch

    // MARK: - Core State

    var sequence: ChoiceSequence
    var tree: ChoiceTree
    var output: Any
    var graph: ChoiceGraph
    var stats: ReductionStats = .init()
    var rejectCache: Set<UInt64> = []
    let gen: AnyGenerator
    let property: (Any) -> Bool
    let tuning: SchedulerTuning
    let collectStats: Bool
    let isInstrumented: Bool

    // MARK: - Loop Control

    var cycles: Int = 0
    var stallBudget: Int
    let maxStalls: Int
    var deferBindInner: Bool
    var graphIsStripped: Bool = false

    // MARK: - Per-Cycle State

    var sources: [any CandidateSource] = []
    var gate: BoundValueGate
    var scopeRejectionCache: CandidateRejectionCache = .init()
    var anyAccepted: Bool = false
    var hadReplacementShortlexRejection: Bool = false
    var sequenceBeforeCycle: ChoiceSequence = []

    // MARK: - Per-Encoder-Pass State

    var activeEncoder: (any GraphEncoder)?
    var activeTransformation: GraphTransformation?
    var activeBoundValueFingerprint: UInt64?
    var candidateBuffer: ChoiceSequence = []
    var lastProbeAccepted: Bool = false
    var encoderBaseHash: UInt64 = 0
    var encoderHasBind: Bool = false
    var pendingMutation: EncoderProbe?
    var pendingProbeHash: UInt64 = 0
    var pendingDecoderSelection: ChoiceGraphScheduler.DecoderSelection?

    // MARK: - Per-Encoder-Pass Accumulators

    var encoderProbeCount: Int = 0
    var encoderAcceptCount: Int = 0
    var encoderCacheHitCount: Int = 0
    var encoderDecoderRejectCount: Int = 0
    var encoderAnyAccepted: Bool = false
    var encoderAnyRequiresRebuild: Bool = false
    var encoderLatestTreeIsStripped: Bool = false

    // MARK: - Init

    init<Output>(
        gen: Generator<Output>,
        initialTree: ChoiceTree,
        initialOutput: Output,
        config: Interpreters.ReducerConfiguration,
        collectStats: Bool,
        property: @escaping (Output) -> Bool
    ) {
        let erasedGen = gen.erase()
        let wrappedProperty: (Any) -> Bool = { property($0 as! Output) } // swiftlint:disable:this force_cast

        var sequence = ChoiceSequence.flatten(initialTree)
        var tree = initialTree
        if case let .success(_, fullTree, _) = Materializer.materializeAny(
            erasedGen,
            prefix: sequence,
            mode: .exact,
            fallbackTree: initialTree,
            materializePicks: true
        ) {
            tree = fullTree
            sequence = ChoiceSequence(fullTree)
        }

        var graph = ChoiceGraph.build(from: tree)
        graph.observeBindTopologies(tree: tree)

        self.sequence = sequence
        self.tree = tree
        self.output = initialOutput
        self.graph = graph
        self.gen = erasedGen
        self.property = wrappedProperty
        self.tuning = config.tuning
        self.collectStats = collectStats
        self.isInstrumented = ExhaustLog.isEnabled(.debug, for: .reducer)
        self.stallBudget = config.maxStalls
        self.maxStalls = config.maxStalls
        self.deferBindInner = graph.reductionEdges.isEmpty == false
        self.gate = BoundValueGate(baseBudget: config.tuning.boundValueBaseBudget)

        if collectStats {
            stats.graphStats = ChoiceGraphStats.from(graph)
        }

        ChoiceGraphScheduler.logReducer("graph_reducer_start", isInstrumented: isInstrumented, metadata: [
            "seq_len": "\(sequence.count)", "max_stalls": "\(config.maxStalls)", "nodes": "\(graph.nodes.count)",
        ])
    }

    // MARK: - Result Extraction

    /// Extracts the final reduced counterexample and accumulated statistics, folding in graph-level stats that were tracked separately during reduction. Call once after ``next()`` returns `nil`.
    mutating func typedResult<Output>() -> (reduced: (ChoiceSequence, Output)?, stats: ReductionStats) {
        stats.graphStats.dynamicRegionRebuilds += graph.graphStats.dynamicRegionRebuilds
        stats.graphStats.dynamicRegionNodesRebuilt += graph.graphStats.dynamicRegionNodesRebuilt
        stats.cycles = cycles
        let finalStats = stats
        // swiftlint:disable:next force_cast
        let typedOutput = output as! Output
        return (reduced: (sequence, typedOutput), stats: finalStats)
    }

    // MARK: - Step

    /// Advances the machine by one step, returning a ``Transition`` that describes what happened, or `nil` when reduction is complete.
    mutating func next() throws -> Transition? {
        switch phase {
        case .beginCycle:
            return stepBeginCycle()
        case .dispatching:
            return try stepDispatching()
        case .endCycle:
            return stepEndCycle()
        case let .postCycle(remaining):
            return try stepPostCycle(remaining: remaining)
        case .checkTermination:
            return stepCheckTermination()
        case .reorderPass:
            return try stepReorderPass()
        case .done:
            return nil
        }
    }

    // MARK: - Begin Cycle

    private mutating func stepBeginCycle() -> Transition {
        cycles += 1
        gate.resetForNewCycle()
        scopeRejectionCache.clearCoarse()
        hadReplacementShortlexRejection = false
        anyAccepted = false
        sequenceBeforeCycle = sequence

        sources = CandidateSourceBuilder.buildSources(from: graph, deferBindInner: deferBindInner)

        ChoiceGraphScheduler.logReducer("graph_cycle_start", isInstrumented: isInstrumented, metadata: [
            "cycle": "\(cycles)", "seq_len": "\(sequence.count)",
            "sources": "\(sources.count)", "stall_budget": "\(stallBudget)",
        ])

        phase = .dispatching
        dispatchPhase = .dispatch
        return .cycleStarted(cycle: cycles, sourceCount: sources.count, sequenceLength: sequence.count)
    }

    // MARK: - End Cycle

    private mutating func stepEndCycle() -> Transition {
        let evaluation = ChoiceGraphScheduler.evaluatePostCycle(
            outcome: ChoiceGraphScheduler.CycleOutcome(
                anyAccepted: anyAccepted,
                hadReplacementShortlexRejection: hadReplacementShortlexRejection,
                allConverged: allValuesConverged(),
                improved: sequence != sequenceBeforeCycle,
                structurallyImproved: sequence.count < sequenceBeforeCycle.count
            ),
            stallBudget: stallBudget,
            maxStalls: maxStalls,
            deferBindInner: deferBindInner
        )

        stallBudget = evaluation.newStallBudget
        deferBindInner = evaluation.newDeferBindInner

        if evaluation.actions.isEmpty {
            phase = .checkTermination
        } else {
            phase = .postCycle(remaining: evaluation.actions)
        }
        return .cycleEnded(stallBudget: stallBudget)
    }

    // MARK: - Post-Cycle Actions

    private mutating func stepPostCycle(
        remaining: [ChoiceGraphScheduler.PostCycleAction]
    ) throws -> Transition {
        guard let action = remaining.first else {
            phase = .checkTermination
            return .cycleEnded(stallBudget: stallBudget)
        }
        let rest = Array(remaining.dropFirst())
        phase = rest.isEmpty ? .checkTermination : .postCycle(remaining: rest)

        switch action {
        case .confirmConvergence:
            let anyStale = try confirmConvergence()
            return .convergenceConfirmed(anyStale: anyStale)
        case .relaxRound:
            let improved = try runRelaxRound()
            if improved {
                anyAccepted = true
                scopeRejectionCache.clear()
            }
            return .relaxRoundCompleted(improved: improved)
        case .releaseDeferral:
            ChoiceGraphScheduler.logReducer("bind_inner_deferral_released", isInstrumented: isInstrumented, metadata: [
                "cycle": "\(cycles)", "seq_len": "\(sequence.count)",
            ])
            return .deferralReleased
        }
    }

    // MARK: - Check Termination

    private mutating func stepCheckTermination() -> Transition {
        let structurallyImproved = sequence.count < sequenceBeforeCycle.count
        if structurallyImproved == false,
           anyAccepted == false,
           allValuesConverged()
        {
            phase = .reorderPass
        } else if stallBudget > 0 {
            ChoiceGraphScheduler.logReducer("graph_cycle_end", isInstrumented: isInstrumented, metadata: [
                "cycle": "\(cycles)", "improved": "\(sequence != sequenceBeforeCycle ? "true" : "false")",
                "seq_len": "\(sequence.count)", "total_mats": "\(stats.totalMaterializations)",
            ])
            phase = .beginCycle
        } else {
            phase = .reorderPass
        }

        if case .reorderPass = phase {
            if isInstrumented {
                ExhaustLog.notice(
                    category: .reducer,
                    event: "graph_reducer_complete",
                    metadata: [
                        "cycles": "\(cycles)",
                        "seq_len": "\(sequence.count)",
                        "total_mats": "\(stats.totalMaterializations)",
                    ]
                )
            }
        }

        if case .beginCycle = phase {
            return .cycleEnded(stallBudget: stallBudget)
        }
        return .terminated
    }

    // MARK: - Reorder Pass

    private mutating func stepReorderPass() throws -> Transition {
        let accepted = try runReorderPass()
        phase = .done
        return .reorderCompleted(accepted: accepted)
    }

    // MARK: - Helpers

    mutating func countMaterialization() {
        if collectStats {
            stats.totalMaterializations += 1
        }
    }

    func allValuesConverged() -> Bool {
        ChoiceGraphScheduler.allValuesConverged(in: sequence, graph: graph)
    }

    private mutating func runReorderPass() throws -> Bool {
        guard let reorderScope = ReorderingQuery.build(graph: graph) else { return false }
        let reorderTransformation = GraphTransformation(
            operation: .reorder(reorderScope),
            priority: DispatchPriority(structuralBenefit: 0, valueBenefit: 0, reductionMagnitude: 0, estimatedCost: 1)
        )
        let reorderScopeBundle = EncoderInput(
            transformation: reorderTransformation,
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        )
        var reorderEncoder: any GraphEncoder = GraphReorderEncoder()
        let savedRejectCache = rejectCache
        rejectCache = []
        let reorderOutcome = try ChoiceGraphScheduler.runProbeLoop(
            encoder: &reorderEncoder,
            scope: reorderScopeBundle,
            state: &self
        )
        rejectCache = savedRejectCache
        if isInstrumented, reorderOutcome.accepted {
            ExhaustLog.notice(category: .reducer, event: "graph_human_order_accepted")
        }
        return reorderOutcome.accepted
    }

    /// Rebuilds the ``ChoiceGraph`` from the current tree, inheriting bind classifications and convergence records from the previous graph. Returns the diff so the caller can decide whether to rebuild structural or value-only sources.
    mutating func rebuildAndUpdateGraph() -> ChoiceGraphDiff {
        stats.graphStats.dynamicRegionRebuilds += graph.graphStats.dynamicRegionRebuilds
        stats.graphStats.dynamicRegionNodesRebuilt += graph.graphStats.dynamicRegionNodesRebuilt
        let oldConvergence = ChoiceGraphScheduler.extractAllConvergence(from: graph)
        let inheritedClassifications = graph.bindClassifications
        let inheritedObservations = graph.bindTopologyObservations
        var newGraph = ChoiceGraph.build(
            from: tree,
            inheriting: inheritedClassifications,
            observations: inheritedObservations
        )
        newGraph.observeBindTopologies(tree: tree)
        ChoiceGraphScheduler.transferConvergence(oldConvergence, to: &newGraph)
        let diff = ChoiceGraphDiff.diff(old: graph, new: newGraph)
        stats.graphStats.fullGraphRebuilds += 1
        graph = newGraph
        return diff
    }
}
