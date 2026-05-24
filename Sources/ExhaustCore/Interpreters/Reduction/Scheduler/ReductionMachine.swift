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
/// The ``dispatching`` phase uses three sub-phases (``DispatchPhase``): select and evaluate a source (``dispatch``), delegate to the active ``ProbeSession`` for encode-decode stepping (``probing``), and optionally rebuild the graph after a structural acceptance (``rebuild``).
package struct ReductionMachine: ProbeSessionState {
    // MARK: - Phase

    /// Tracks which stage of the reduction pipeline the machine is in. The outer loop cycles through ``beginCycle`` → ``dispatching`` → ``endCycle`` → ``postCycle`` → ``checkTermination``, exiting via ``reorderPass`` → ``done`` when the stall budget is exhausted or all values converge.
    enum Phase {
        case beginCycle
        case buildSources
        case dispatching
        case endCycle
        case postCycle(remaining: [ChoiceGraphScheduler.PostCycleAction])
        case checkTermination
        case reorderPass
        case done
    }

    /// Tracks where the machine is within a single ``Phase/dispatching`` step.
    enum DispatchPhase {
        case dispatch
        case probing
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
        case cycleStarted(cycle: Int, sequenceLength: Int)
        case sourcesBuilt(sourceCount: Int)
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
    let enabledEncoders: Set<EncoderName>?
    let collectStats: Bool
    let isInstrumented: Bool

    // MARK: - Convergence Tracker

    /// Owns the reduction loop's termination and phase-transition state.
    ///
    /// Four components work together to decide when reduction is complete:
    ///
    /// - **stallBudget**: Global termination signal. Counts cycles without progress (no accepted probes and no structural improvement). When exhausted, the reducer exits to the reorder pass.
    /// - **deferBindInner**: Structural/value phase boundary. Structural work (deletion, replacement, migration) runs first with bind-inner scopes deferred. When structural reduction stalls, the deferral is released and value search on bind-inner leaves begins.
    /// - **gate**: Per-bind-site dispatch control. Prevents redundant bound-value composition probing by tracking which bind sites have been dispatched, which are fruitless, and applying exponential budget decay on repeated stalls.
    ///
    /// Per-leaf convergence data lives in ``ChoiceGraph/convergenceStore``, keyed by node ID. It is warm-start data for encoders, not loop-control state. The ``confirmConvergence()`` post-cycle action probes those records for staleness and clears any that a structural change has invalidated.
    struct ConvergenceTracker {
        var stallBudget: Int
        let maxStalls: Int
        var deferBindInner: Bool
        var gate: BoundValueGate

        func evaluatePostCycle(
            outcome: ChoiceGraphScheduler.CycleOutcome
        ) -> ChoiceGraphScheduler.PostCycleEvaluation {
            ChoiceGraphScheduler.evaluatePostCycle(
                outcome: outcome,
                stallBudget: stallBudget,
                maxStalls: maxStalls,
                deferBindInner: deferBindInner
            )
        }

        mutating func apply(_ evaluation: ChoiceGraphScheduler.PostCycleEvaluation) {
            stallBudget = evaluation.newStallBudget
            deferBindInner = evaluation.newDeferBindInner
        }

        mutating func resetForNewCycle() {
            gate.resetForNewCycle()
        }
    }

    // MARK: - Loop Control

    var cycles: Int = 0
    var convergence: ConvergenceTracker
    var graphIsStripped: Bool = false
    let deadlineNanoseconds: UInt64
    let startNanoseconds: UInt64

    // MARK: - Per-Cycle State

    var sources: [AnyCandidateSource] = []
    var scopeRejectionCache: CandidateRejectionCache = .init()
    var anyAccepted: Bool = false
    var hadReplacementShortlexRejection: Bool = false
    var sequenceBeforeCycle: ChoiceSequence = []

    // MARK: - Active Probe Session

    var activeSession: ProbeSession?
    var pendingReport: PassReport?

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
        output = initialOutput
        self.graph = graph
        self.gen = erasedGen
        self.property = wrappedProperty
        tuning = config.tuning
        enabledEncoders = config.enabledEncoders
        self.collectStats = collectStats
        isInstrumented = ExhaustLog.isEnabled(.debug, for: .reducer)
        convergence = ConvergenceTracker(
            stallBudget: config.maxStalls,
            maxStalls: config.maxStalls,
            deferBindInner: graph.reductionEdges.isEmpty == false,
            gate: BoundValueGate(baseBudget: config.tuning.boundValueBaseBudget)
        )
        deadlineNanoseconds = config.wallClockDeadlineNanoseconds
        startNanoseconds = deadlineNanoseconds > 0 ? monotonicNanoseconds() : 0

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
            case .buildSources:
                return stepBuildSources()
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
        convergence.resetForNewCycle()
        scopeRejectionCache.clearCoarse()
        hadReplacementShortlexRejection = false
        anyAccepted = false
        sequenceBeforeCycle = sequence

        phase = .buildSources
        return .cycleStarted(cycle: cycles, sequenceLength: sequence.count)
    }

    private mutating func stepBuildSources() -> Transition {
        sources = CandidateSourceBuilder.buildSources(from: graph, deferBindInner: convergence.deferBindInner)

        ChoiceGraphScheduler.logReducer("graph_cycle_start", isInstrumented: isInstrumented, metadata: [
            "cycle": "\(cycles)", "seq_len": "\(sequence.count)",
            "sources": "\(sources.count)", "stall_budget": "\(convergence.stallBudget)",
        ])

        phase = .dispatching
        dispatchPhase = .dispatch
        return .sourcesBuilt(sourceCount: sources.count)
    }

    // MARK: - End Cycle

    private mutating func stepEndCycle() -> Transition {
        let evaluation = convergence.evaluatePostCycle(
            outcome: ChoiceGraphScheduler.CycleOutcome(
                anyAccepted: anyAccepted,
                hadReplacementShortlexRejection: hadReplacementShortlexRejection,
                allConverged: allValuesConverged(),
                improved: sequence != sequenceBeforeCycle,
                structurallyImproved: sequence.count < sequenceBeforeCycle.count
            )
        )

        convergence.apply(evaluation)

        if evaluation.actions.isEmpty {
            phase = .checkTermination
        } else {
            phase = .postCycle(remaining: evaluation.actions)
        }
        return .cycleEnded(stallBudget: convergence.stallBudget)
    }

    // MARK: - Post-Cycle Actions

    private mutating func stepPostCycle(
        remaining: [ChoiceGraphScheduler.PostCycleAction]
    ) throws -> Transition {
        guard let action = remaining.first else {
            phase = .checkTermination
            return .cycleEnded(stallBudget: convergence.stallBudget)
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
        } else if convergence.stallBudget > 0 {
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
            return .cycleEnded(stallBudget: convergence.stallBudget)
        }
        return .terminated
    }

    // MARK: - Reorder Pass

    private mutating func stepReorderPass() throws -> Transition {
        let skipReorder = enabledEncoders.map { $0.contains(.numericReorder) == false } ?? false
        let accepted = skipReorder ? false : try runReorderPass()
        phase = .done
        return .reorderCompleted(accepted: accepted)
    }

    // MARK: - Helpers

    func isDeadlineExceeded() -> Bool {
        guard deadlineNanoseconds > 0 else { return false }
        return monotonicNanoseconds() - startNanoseconds >= deadlineNanoseconds
    }

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
        let scope = EncoderInput(
            transformation: reorderTransformation,
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        )
        var encoder: any GraphEncoder = GraphReorderEncoder()
        encoder.start(scope: scope)

        let savedRejectCache = rejectCache
        rejectCache = []

        var session = ProbeSession(
            encoder: encoder,
            transformation: reorderTransformation,
            boundValueFingerprint: nil,
            baseSequence: sequence,
            hasBind: sequence.contains { if case .bind = $0 { return true }; return false }
        )
        let report = try session.runToCompletion(state: &self)

        rejectCache = savedRejectCache

        _ = applyPassReport(report)

        if isInstrumented, report.anyAccepted {
            ExhaustLog.notice(category: .reducer, event: "graph_human_order_accepted")
        }
        return report.anyAccepted
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
