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
/// The machine moves through cycle stages and final presentation work:
///
/// ```
/// beginCycle → dispatching ⟳ → endCycle → postCycle → checkTermination
///            → beginCycle | reorderPass → done
/// ```
///
/// The ``dispatching`` phase uses three sub-phases (``DispatchPhase``): select and evaluate a source (``dispatch``), delegate to the active ``ProbeSession`` for encode-decode stepping (``probing``), and optionally rebuild the graph after a structural acceptance (``rebuild``).
///
/// Session-backed post-cycle actions and final reorder use ``Phase/postCycleProbing(pass:remaining:)`` to yield between encoding and decoding while retaining their own reporting bucket.
/// Excursions suspend the outer cycle while an ``ExcursionFrame`` steps perturbation and a nested exploitation loop, then commits or restores the checkpoint.
package struct ReductionMachine: ProbeSessionState {
    // MARK: - Phase

    /// Tracks which stage of the reduction pipeline the machine is in. The outer loop cycles through ``beginCycle`` → ``dispatching`` → ``endCycle`` → ``postCycle`` → ``checkTermination``, exiting via ``reorderPass`` → ``done`` when the stall budget is exhausted or all values converge.
    enum Phase {
        case beginCycle
        case buildSources
        case dispatching
        case endCycle
        case postCycle(remaining: [ChoiceGraphScheduler.PostCycleAction])
        case postCycleProbing(pass: PostCyclePass, remaining: [ChoiceGraphScheduler.PostCycleAction])
        case excursion(remaining: [ChoiceGraphScheduler.PostCycleAction])
        case checkTermination
        case reorderPass
        case done
    }

    /// Names the dispatch loop's sub-phase for callers that inspect machine progress.
    typealias DispatchPhase = DispatchLoop.SubPhase

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
        /// A completed encoder pass applied its bookkeeping and selected the next dispatch phase.
        case passCompleted(encoder: EncoderName, accepted: Bool)
        case rebuilt(sequenceLength: Int, structurallyChanged: Bool)

        case convergenceConfirmed(anyStale: Bool)
        case improvingPivotsCompleted(improved: Bool)
        case excursionAdvanced(step: ExcursionStep)
        case excursionCompleted(improved: Bool)
        case relationPassCompleted(accepted: Bool)
        case stagedJointPassCompleted(accepted: Bool)
        case deferralReleased

        case postCycleStarted(owner: PostCycleTiming)
        case postCycleEncoded(owner: PostCycleTiming, encoder: EncoderName, cacheHit: Bool)
        case postCycleDecoded(owner: PostCycleTiming, encoder: EncoderName, accepted: Bool)

        case reorderCompleted(accepted: Bool)
        case terminated
    }

    /// Reports provisional excursion work without attributing nested dispatch and probing to the ordinary cycle's timing buckets.
    package enum ExcursionStep {
        case started
        case perturbed(accepted: Bool)
        case exploitationStarted(sourceCount: Int)
        case dispatched(decision: DispatchOutcome)
        case encoded(encoder: EncoderName, cacheHit: Bool)
        case decoded(encoder: EncoderName, accepted: Bool)
        case passCompleted(encoder: EncoderName, accepted: Bool)
        case rebuilt(sequenceLength: Int, structurallyChanged: Bool)
    }

    /// Owns the reporting bucket for every step of a session-backed post-cycle pass, including setup and completion.
    package enum PostCycleTiming {
        case relationPass
        case stagedJointPass
        case reorder
    }

    /// Retains continuation state across probes; final reorder also owns the rejection cache it temporarily replaced.
    enum PostCyclePass {
        case relation
        case stagedJoint(StagedJointSearch)
        case reorder(savedRejectCache: Set<UInt64>)

        var timing: PostCycleTiming {
            switch self {
                case .relation: .relationPass
                case .stagedJoint: .stagedJointPass
                case .reorder: .reorder
            }
        }
    }

    // MARK: - State

    var phase: Phase = .beginCycle
    var dispatchLoop = DispatchLoop(policy: .main)
    /// Present only during ``Phase/excursion(remaining:)``; removed while stepping to avoid retaining copies of the nested loop's sources.
    var excursionFrame: ExcursionFrame?

    var dispatchPhase: DispatchPhase {
        get { dispatchLoop.subPhase }
        set { dispatchLoop.subPhase = newValue }
    }

    // MARK: - Core State

    let initialSequence: ChoiceSequence
    var sequence: ChoiceSequence
    var tree: ChoiceTree
    var output: Any
    var graph: ChoiceGraph
    var stats: ReductionStats = .init()
    var rejectCache: Set<UInt64> = []
    /// Shared with every bound value composition the machine builds; folded into ``stats`` by ``typedResult()``.
    let boundValueBuildTally = BoundValueBuildTally()
    let gen: AnyGenerator
    let property: (Any) -> Bool
    let probeWrapper: ProbeWrapper?
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
    /// Uses the production monotonic clock by default; an injected clock makes deadline boundaries deterministic in tests.
    private let currentNanoseconds: () -> UInt64

    // MARK: - Per-Cycle State

    var sources: [AnyCandidateSource] {
        get { dispatchLoop.sources }
        set { dispatchLoop.sources = newValue }
        _modify { yield &dispatchLoop.sources }
    }

    var scopeRejectionCache: CandidateRejectionCache = .init()
    var anyAccepted: Bool = false
    var hadUnresolvedReplacement: Bool = false

    /// True from the post-cycle action that releases the bind-inner deferral until the next cycle begins, when the release adds at least one scope. The termination check reads it so the cycle that releases the deferral is followed by one more, without consulting the stall budget or the convergence check: the deferred scopes were never built into any source, so the stall that released them says nothing about whether they would accept, and a run whose leaves are all at target would otherwise terminate as converged without ever dispatching them. The deferral is released once per run, so the bypass is bounded to one cycle.
    var deferralReleasedThisCycle: Bool = false

    /// True once any pass in the run accepted a probe. Unlike ``anyAccepted``, never reset: a run that terminates with this still false could not improve the input even once, which is the silent-stall presentation the stall diagnostic warns about.
    var anyAcceptanceEverOccurred: Bool = false

    /// Consecutive migration passes that rejected every probe, across the whole run. Reset by any migration acceptance. When this reaches ``SchedulerTuning/migrationDemotionThreshold`` (and the threshold is nonzero), dispatch skips migration transformations for the rest of the run.
    var migrationConsecutiveRejects: Int = 0
    var sequenceBeforeCycle: ChoiceSequence = []

    var exhaustedStagedJointScope: ExhaustedStagedJointScope?

    // MARK: - Coupling Attribution

    /// Log of value changes, ordered by pass. Each entry records which nodes changed in an accepted pass. Used to attribute coupling edges by scanning entries between a node's last convergence and the current pass.
    var valueChangeLog: [(passIndex: Int, nodeIDs: Set<Int>)] = []

    /// The pass index at which each node's convergence was last recorded. When floor motion is detected at node A, the coupling partners are nodes that changed in passes after `lastConvergencePass[A]`.
    var lastConvergencePass: [Int: Int] = [:]

    /// Maintains bounded coupling hints for joint-group ranking without enabling research diagnostics.
    var couplingTracker = CouplingTracker()

    /// Monotonic pass counter incremented on each `applyPassPolicy` call.
    var passCounter: Int = 0

    // MARK: - Research Diagnostics

    /// Enables the research diagnostics: floor-motion counters, coupling attribution (`couplingDependents`, coupling edges, partner counts), redistribution acceptance sets, and the per-dispatch log that feeds the `dispatch_stats` and `indexability` benchmark reports. Deliberately a maintainer-set literal rather than configuration surface: `collectStats` is always on in normal use, so these per-pass costs (attribution scans, two O(*n*) distance sums, record appends) must not ride it. Flip to true for a diagnostics session over the benchmark suite; the benchmark report blocks appear only when this was set.
    var collectDiagnostics = false

    /// Sequence length at the start of the pass currently in flight. Captured by ``captureDispatchBaseline()`` so ``applyPassPolicy(_:)`` can record the pass's ``DispatchRecord/sequenceLengthDelta``.
    var dispatchBaselineLength: Int = 0

    /// Total distance-to-reduction-target at the start of the pass currently in flight.
    var dispatchBaselineTargetDistance: Double = 0

    // MARK: - Active Probe Session

    var activeSession: ProbeSession? {
        get { dispatchLoop.activeSession }
        set { dispatchLoop.activeSession = newValue }
        _modify { yield &dispatchLoop.activeSession }
    }

    var pendingReport: PassReport? {
        get { dispatchLoop.pendingReport }
        set { dispatchLoop.pendingReport = newValue }
    }

    // MARK: - Init

    init<Output>(
        gen: Generator<Output>,
        initialTree: ChoiceTree,
        initialOutput: Output,
        config: Interpreters.ReducerConfiguration,
        collectStats: Bool,
        currentNanoseconds: @escaping () -> UInt64 = MonotonicClock.nanoseconds,
        property: @escaping (Output) -> Bool
    ) {
        let erasedGen = gen.erase()
        let wrappedProperty: (Any) -> Bool = { property($0 as! Output) } // swiftlint:disable:this force_cast

        var sequence = ChoiceSequence.flatten(initialTree)
        var tree = initialTree
        var setupMaterializations = 1
        if case let .success(_, fullTree, _) = Materializer.materializeAny(
            erasedGen,
            context: .init(
                prefix: sequence,
                mode: .exact,
                fallbackTree: initialTree,
                materializePicks: true
            )
        ) {
            tree = fullTree
            sequence = ChoiceSequence(fullTree)
        }
        // Once, before the first graph build.
        let reencoded = ConstantArmReencoder.reencode(
            sequence: sequence,
            tree: tree,
            gen: erasedGen,
            materializations: &setupMaterializations
        )
        if let reencoded {
            sequence = reencoded.sequence
            tree = reencoded.tree
        }

        var graph = ChoiceGraph.build(from: tree)
        graph.observeBindTopologies(tree: tree)
        graph.excludedPivots = reencoded?.excludedPivots ?? []

        initialSequence = sequence
        self.sequence = sequence
        self.tree = tree
        output = initialOutput
        self.graph = graph
        self.gen = erasedGen
        self.property = wrappedProperty
        probeWrapper = config.probeWrapper
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
        self.currentNanoseconds = currentNanoseconds
        startNanoseconds = deadlineNanoseconds > 0 ? currentNanoseconds() : 0

        if collectStats {
            stats.graphStats = ChoiceGraphStats.from(graph)
            stats.recordMaterializations(setupMaterializations, at: .setup)
        }

        ChoiceGraphScheduler.logReducer("graph_reducer_start", isInstrumented: isInstrumented, metadata: [
            "seq_len": "\(sequence.count)", "max_stalls": "\(config.maxStalls)", "nodes": "\(graph.nodes.count)",
        ])
    }

    // MARK: - Result Extraction

    /// Extracts the final reduced counterexample and accumulated statistics, folding in graph-level stats that were tracked separately during reduction. Call once after ``next()`` returns `nil`.
    mutating func typedResult<Output>() -> (outcome: ReductionOutcome<Output>, stats: ReductionStats) {
        stats.graphStats.dynamicRegionRebuilds += graph.graphStats.dynamicRegionRebuilds
        stats.graphStats.dynamicRegionNodesRebuilt += graph.graphStats.dynamicRegionNodesRebuilt
        stats.cycles = cycles
        stats.boundValueBuildOutcomes = boundValueBuildTally.counts
        if collectStats {
            stats.recordMaterializations(boundValueBuildTally.total, at: .boundValueLift)
        }
        let finalStats = stats
        // swiftlint:disable:next force_cast
        let typedOutput = output as! Output
        let outcome: ReductionOutcome<Output> = sequence != initialSequence
            ? .reduced(sequence, tree, typedOutput)
            : .unreduced(sequence, tree, typedOutput)
        return (outcome: outcome, stats: finalStats)
    }

    // MARK: - Step

    /// Advances one cooperative step, preserving in-flight work in a final report when the deadline expires.
    ///
    /// Checks before starting each step and after it returns. An in-flight materialization or property call completes normally; expiry stops subsequent search work. The enabled final numeric reorder pass still runs to completion after expiry, including its materializations and property calls, to preserve the returned counterexample's presentation.
    mutating func next() -> Transition? {
        if case .done = phase {
            return nil
        }
        guard isDeadlineExceeded() == false else {
            return finishAtDeadline()
        }
        let transition: Transition? = switch phase {
            case .beginCycle:
                stepBeginCycle()
            case .buildSources:
                stepBuildSources()
            case .dispatching:
                stepDispatching()
            case .endCycle:
                stepEndCycle()
            case let .postCycle(remaining):
                stepPostCycle(remaining: remaining)
            case let .postCycleProbing(pass, remaining):
                stepPostCycleProbing(pass: pass, remaining: remaining)
            case let .excursion(remaining):
                stepExcursion(remaining: remaining)
            case .checkTermination:
                stepCheckTermination()
            case .reorderPass:
                stepReorderPass()
            case .done:
                nil
        }
        if isDeadlineExceeded() {
            _ = finishAtDeadline()
        }
        return transition
    }

    // MARK: - Begin Cycle

    private mutating func stepBeginCycle() -> Transition {
        cycles += 1
        convergence.resetForNewCycle()
        scopeRejectionCache.clearCoarse()
        // Latched across stalled cycles: the scope rejection cache can skip a replacement scope on the very stall that schedules the excursion.
        hadUnresolvedReplacement = hadUnresolvedReplacement && sequence == sequenceBeforeCycle
        anyAccepted = false
        deferralReleasedThisCycle = false
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
        // A stripped graph has no pivot scopes.
        if anyAccepted == false, graphIsStripped, isEncoderEnabled(.branchPivot), tuning.relaxImprovingProbeBudget > 0 {
            rematerializeUnselectedBranches()
        }
        let evaluation = ChoiceGraphScheduler.evaluatePostCycle(
            outcome: ChoiceGraphScheduler.CycleOutcome(
                anyAccepted: anyAccepted,
                hadUnresolvedReplacement: hadUnresolvedReplacement,
                // The pivot's source is spent in the cycle that probed it, so no encoder sees it in the stalled cycle and the graph has to answer.
                hasUnprobedImprovingPivot: anyAccepted == false && hasUnprobedImprovingPivot,
                allConverged: allValuesConverged(),
                improved: sequence != sequenceBeforeCycle,
                structurallyImproved: sequence.count < sequenceBeforeCycle.count,
                shouldAttemptStagedJoint: anyAccepted == false && pendingStagedNumericPairs() != nil
            ),
            stallBudget: convergence.stallBudget,
            maxStalls: convergence.maxStalls,
            deferBindInner: convergence.deferBindInner
        )

        convergence.apply(evaluation)

        let actions = evaluation.actions.filter(isPostCycleActionEnabled)
        if actions.isEmpty {
            phase = .checkTermination
        } else {
            phase = .postCycle(remaining: actions)
        }
        return .cycleEnded(stallBudget: convergence.stallBudget)
    }

    // MARK: - Post-Cycle Actions

    private mutating func stepPostCycle(
        remaining: [ChoiceGraphScheduler.PostCycleAction]
    ) -> Transition {
        guard let action = remaining.first else {
            phase = .checkTermination
            return .cycleEnded(stallBudget: convergence.stallBudget)
        }
        let rest = Array(remaining.dropFirst())
        phase = rest.isEmpty ? .checkTermination : .postCycle(remaining: rest)

        switch action {
            case .confirmConvergence:
                let anyStale = confirmConvergence()
                return .convergenceConfirmed(anyStale: anyStale)
            case .relationPass:
                return startRelationPass(remaining: rest)
            case .improvingPivots:
                let improved = runImprovingPivotPass()
                if improved {
                    recordPostCycleAcceptance()
                }
                return .improvingPivotsCompleted(improved: improved)
            case .stagedJointPass:
                return startStagedJointPass(remaining: rest)
            case .excursion:
                // Perturbing away from a counterexample that an earlier action just improved spends budget escaping a local minimum the run may not be in.
                guard anyAccepted == false else {
                    return .excursionCompleted(improved: false)
                }
                return startExcursion(remaining: rest)
            case .releaseDeferral:
                // Only worth a cycle when lifting the deferral adds scopes: a bind whose inner holds neither a leaf nor a pick contributes none, and the extra cycle would replay the structural sources for nothing.
                deferralReleasedThisCycle = MinimizationQuery.deferredScopes(graph: graph, stopAtFirst: true).isEmpty == false
                ChoiceGraphScheduler.logReducer("bind_inner_deferral_released", isInstrumented: isInstrumented, metadata: [
                    "cycle": "\(cycles)", "seq_len": "\(sequence.count)",
                ])
                return .deferralReleased
        }
    }

    /// Records an acceptance made by a post-cycle pass: marks the cycle accepted, drops scope rejections recorded against the previous sequence, and restores the stall budget.
    ///
    /// The stall that scheduled the pass has already been spent, and the excursion only runs on the stall that would end the run. Without fresh budget the run could stop before ordinary reduction, bind search included, reaches the accepted counterexample.
    mutating func recordPostCycleAcceptance() {
        anyAccepted = true
        anyAcceptanceEverOccurred = true
        scopeRejectionCache.clear()
        convergence.stallBudget = convergence.maxStalls
    }

    /// Records an acceptance whose effect can reach beyond the edited leaves, because the property couples values the generator treats as independent. Every convergence floor, cached rejection, and bind search history is invalidated on top of ``recordPostCycleAcceptance()``.
    mutating func invalidateAfterCoupledAcceptance() {
        recordPostCycleAcceptance()
        graph.convergenceStore.removeAll()
        rejectCache.removeAll()
        convergence.gate.invalidateSearchHistory()
    }

    // MARK: - Check Termination

    private mutating func stepCheckTermination() -> Transition {
        let structurallyImproved = sequence.count < sequenceBeforeCycle.count
        if deferralReleasedThisCycle {
            phase = .beginCycle
        } else if structurallyImproved == false,
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

    private mutating func stepReorderPass() -> Transition {
        guard isEncoderEnabled(.numericReorder), let session = makeReorderSession() else {
            return completeReorderPass(accepted: false)
        }
        let savedRejectCache = rejectCache
        rejectCache = []
        captureDispatchBaseline()
        activeSession = session
        phase = .postCycleProbing(pass: .reorder(savedRejectCache: savedRejectCache), remaining: [])
        return .postCycleStarted(owner: .reorder)
    }

    /// Finalizes diagnostics after the reorder session has applied its report and restored the rejection cache.
    mutating func completeReorderPass(accepted: Bool) -> Transition {
        recordStallDiagnostic()
        phase = .done
        return .reorderCompleted(accepted: accepted)
    }

    /// Populates the stall-diagnostic fields on ``ReductionStats`` at termination.
    ///
    /// A leaf is stalled when it holds a convergence record whose bound equals its current bit pattern while that pattern differs from the reduction target: the encoder proved the leaf cannot move alone, and it did not reach its target. Leaf counts use the graph from before final numeric reordering, which does not update the graph; the acceptance flag includes that final pass. Stalled leaves are normal at the end of a successful reduction (a property demanding nonzero values leaves every surviving leaf short of its target), so the count alone is not a warning signal — the warning condition is a nonzero count on a run where ``anyAcceptanceEverOccurred`` is still false. Control-scope leaves (depth, lane, bind-inner) are machinery, not user values, and are excluded.
    private mutating func recordStallDiagnostic() {
        var stalledCount = 0
        var residualDistance: Double = 0
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else {
                continue
            }
            let annotation = node.scopeAnnotation
            if annotation.isDepthControl || annotation.isLaneControl || annotation.isBindInner {
                continue
            }
            let bitPattern = metadata.value.bitPattern64
            let target = metadata.value.reductionTarget(in: metadata.validRange)
            guard bitPattern != target else {
                continue
            }
            guard let record = graph.convergenceStore[nodeID], record.bound == bitPattern else {
                continue
            }
            stalledCount += 1
            residualDistance += Double(bitPattern > target ? bitPattern - target : target - bitPattern)
        }
        stats.stalledLeafCount = stalledCount
        stats.stalledLeafResidualDistance = residualDistance
        stats.anyAcceptanceEverOccurred = anyAcceptanceEverOccurred
    }

    // MARK: - Helpers

    /// Applies an interrupted search session exactly once, then runs the enabled final numeric reorder pass without rebuilding candidate sources.
    ///
    /// A pending structural acceptance rebuilds only the graph needed for final reordering and stall diagnostics. The decoded sequence, tree, and output are already committed; cosmetic reordering never needs a graph rebuild after its final value is accepted.
    mutating func finishAtDeadline() -> Transition {
        stats.reductionWasCapped = true
        if case .done = phase {
            return .terminated
        }
        if var frame = excursionFrame {
            excursionFrame = nil
            if frame.finishAtDeadline(state: &self) {
                recordPostCycleAcceptance()
            }
        }
        if case let .postCycleProbing(pass, _) = phase {
            if let session = activeSession {
                activeSession = nil
                switch pass {
                    case let .reorder(savedRejectCache):
                        let report = session.runToCompletion(state: &self)
                        finishReorderReport(report, savedRejectCache: savedRejectCache)
                        pendingReport = nil
                        sources = []
                        _ = completeReorderPass(accepted: report.anyAccepted)
                        return .terminated
                    case .relation:
                        finishRelationReport(session.report())
                    case .stagedJoint:
                        let report = session.report()
                        applyPostCycleReport(report)
                        if report.anyAccepted {
                            invalidateAfterCoupledAcceptance()
                        }
                }
            }
        }
        if let session = activeSession {
            let report = session.report()
            activeSession = nil
            pendingReport = report
            _ = applyPassPolicy(report)
        }
        if let report = pendingReport, report.anyAccepted, report.anyRequiresRebuild {
            _ = rebuildAndUpdateGraph(
                valueGuardExemptNodeIDs: report.acceptedLeafNodeIDs.union(report.convergenceRecords.keys)
            )
            graphIsStripped = report.latestTreeIsStripped
        }
        pendingReport = nil
        sources = []
        let accepted = isEncoderEnabled(.numericReorder) ? runReorderPass() : false
        _ = completeReorderPass(accepted: accepted)
        return .terminated
    }

    /// Treats zero as unlimited; otherwise compares elapsed time on the same monotonic clock used at initialization.
    func isDeadlineExceeded() -> Bool {
        guard deadlineNanoseconds > 0 else {
            return false
        }
        return currentNanoseconds() - startNanoseconds >= deadlineNanoseconds
    }

    /// Captures the deadline bounds rather than `self`, for passes that hold `self` `inout` while checking it.
    func makeDeadlineCheck() -> () -> Bool {
        let deadline = deadlineNanoseconds
        let start = startNanoseconds
        let clock = currentNanoseconds
        return {
            guard deadline > 0 else {
                return false
            }
            return clock() - start >= deadline
        }
    }

    func allValuesConverged() -> Bool {
        ChoiceGraphScheduler.allValuesConverged(in: sequence, graph: graph)
    }

    /// Builds final reordering work without a deadline gate: an expired search must still finish its presentation pass.
    func makeReorderSession() -> ProbeSession? {
        guard let reorderScope = ReorderingQuery.build(graph: graph) else {
            return nil
        }
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
        var encoder: EncoderDispatch = .init(GraphReorderEncoder())
        encoder.start(scope: scope)

        return ProbeSession(
            encoder: encoder,
            transformation: reorderTransformation,
            boundValueFingerprint: nil,
            baseSequence: sequence,
            hasBind: sequence.contains { entry in
                if case .bind = entry {
                    return true
                }
                return false
            }
        )
    }

    /// Runs final presentation work synchronously when the search deadline has already expired.
    private mutating func runReorderPass() -> Bool {
        guard let session = makeReorderSession() else {
            return false
        }
        let savedRejectCache = rejectCache
        rejectCache = []
        captureDispatchBaseline()
        let report = session.runToCompletion(state: &self)
        finishReorderReport(report, savedRejectCache: savedRejectCache)
        return report.anyAccepted
    }

    /// Snapshots the sequence's length and total target distance ahead of a probe session, so the completed pass's dispatch record can carry improvement deltas. No-op unless diagnostics are enabled.
    mutating func captureDispatchBaseline() {
        guard collectDiagnostics else {
            return
        }
        dispatchBaselineLength = sequence.count
        dispatchBaselineTargetDistance = sequenceTargetDistance()
    }

    /// Sums each value entry's absolute pattern-space distance to its reduction target. Distance to target rather than raw pattern keeps the scalar meaningful for signed encodings and range-constrained values. Floating point because full-range leaves contribute distances near 2^63 and integer sums would overflow.
    func sequenceTargetDistance() -> Double {
        var total: Double = 0
        for entry in sequence {
            guard let value = entry.value else {
                continue
            }
            let bitPattern = value.choice.bitPattern64
            let target = value.choice.reductionTarget(in: value.validRange)
            let distance = bitPattern > target ? bitPattern - target : target - bitPattern
            total += Double(distance)
        }
        return total
    }

    /// Rebuilds the ``ChoiceGraph`` from the current tree, inheriting bind classifications and convergence records from the previous graph. Returns the diff so the caller can decide whether to rebuild structural or value-only sources.
    ///
    /// - Parameter valueGuardExemptNodeIDs: Old-graph leaves whose values are stale because they accepted a change in the pass triggering this rebuild. Their convergence records transfer without the anti-aliasing value guard. See ``ChoiceGraphScheduler/extractAllConvergence(from:valueGuardExemptNodeIDs:)``.
    mutating func rebuildAndUpdateGraph(valueGuardExemptNodeIDs: Set<Int> = []) -> ChoiceGraphDiff {
        stats.graphStats.dynamicRegionRebuilds += graph.graphStats.dynamicRegionRebuilds
        stats.graphStats.dynamicRegionNodesRebuilt += graph.graphStats.dynamicRegionNodesRebuilt
        let oldConvergence = ChoiceGraphScheduler.extractAllConvergence(
            from: graph,
            valueGuardExemptNodeIDs: valueGuardExemptNodeIDs
        )
        let inheritedClassifications = graph.bindClassifications
        let inheritedObservations = graph.bindTopologyObservations
        var newGraph = ChoiceGraph.build(
            from: tree,
            inheriting: inheritedClassifications,
            observations: inheritedObservations,
            excludedPivots: graph.excludedPivots
        )
        newGraph.observeBindTopologies(tree: tree)
        ChoiceGraphScheduler.transferConvergence(oldConvergence, to: &newGraph)
        let diff = ChoiceGraphDiff.diff(old: graph, new: newGraph)
        if diff.canReuseStructuralSources {
            newGraph.couplingDependents = graph.couplingDependents
        } else {
            couplingTracker = CouplingTracker()
        }
        stats.graphStats.fullGraphRebuilds += 1
        graph = newGraph
        return diff
    }
}
