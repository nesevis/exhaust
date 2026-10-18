//
//  ScopedReductionRunner.swift
//  Exhaust
//

// MARK: - Scoped Reduction Runner

/// Owns a complete scoped reduction: setup, cycles of dispatch over the family sources, post-cycle actions, relax rounds, and the final reorder pass.
///
/// The runner is written in direct style. The encoder's reducer for each scope runs to completion in its own interpreter execution, which the runner seeds from its own state and reconciles afterwards. Cycles, post-cycle actions, and relax rounds are ordinary nested calls.
///
/// ## Cycle
///
/// A cycle builds the family sources, dispatches their scopes in priority order until every source is exhausted, then evaluates the cycle: post-cycle actions run on a stall, and the stall budget and convergence decide whether another cycle follows. The final pass reorders sibling groups numerically for presentation.
///
/// ## Deadline
///
/// The deadline is checked between every unit of work, and inside passes before each probe. On expiry, an in-flight pass applies its report, an accepted pass that needs a rebuild rebuilds the graph only, a relax round settles, and the final numeric reorder still runs to completion.
package struct ScopedReductionRunner {
    /// Run-wide settings the runner reads but never changes.
    package struct Configuration {
        /// Cycles without improvement before the run ends.
        let maxStalls: Int
        /// Wall-clock budget for the run. Zero is unlimited.
        let wallClockDeadlineNanoseconds: UInt64
        /// Encoders allowed to dispatch, run post-cycle actions, and exploit relax rounds. Nil enables all; an empty set enables none.
        let enabledEncoders: Set<EncoderName>?
        let tuning: ScopedReductionTuning
        let probeWrapper: ProbeWrapper?

        package init(
            maxStalls: Int,
            wallClockDeadlineNanoseconds: UInt64 = 0,
            enabledEncoders: Set<EncoderName>? = nil,
            tuning: ScopedReductionTuning = ScopedReductionTuning(),
            probeWrapper: ProbeWrapper? = nil
        ) {
            self.maxStalls = maxStalls
            self.wallClockDeadlineNanoseconds = wallClockDeadlineNanoseconds
            self.enabledEncoders = enabledEncoders
            self.tuning = tuning
            self.probeWrapper = probeWrapper
        }
    }

    // MARK: - Core State

    let initialSequence: ChoiceSequence
    /// Every assignment refreshes ``incumbentHash`` and ``hasBind``, which each pass and decoder read.
    var incumbent: ScopedCounterexample {
        didSet {
            incumbentHash = ZobristHash.hash(of: incumbent.sequence)
            hasBind = Self.containsBind(incumbent.sequence)
        }
    }

    private(set) var incumbentHash: UInt64
    /// Whether the incumbent holds a bind, which decides between guided and exact decoding.
    private(set) var hasBind: Bool
    var graph: ChoiceGraph
    var stats = ReductionStats()
    var rejectCache: Set<UInt64> = []
    let generator: AnyGenerator
    let property: (Any) -> Bool
    let probeWrapper: ProbeWrapper?
    let tuning: ScopedReductionTuning
    let enabledEncoders: Set<EncoderName>?
    /// Gates timings, graph statistics, and materialization counts. Probe counts are recorded either way, because callers report property invocations from them.
    let collectStats: Bool
    let isInstrumented: Bool

    // MARK: - Loop Control

    var cycles = 0
    /// Cycles without progress left before the run ends. Restored to ``maxStalls`` by any improvement.
    var stallBudget: Int
    let maxStalls: Int
    /// Per-bind dispatch control for bound value search: per-cycle deduplication, fruitless verdicts, and budget decay.
    var gate: BoundValueGate
    /// Whether the latest tree lacks unselected branches, so pick nodes cannot offer pivots until rematerialized.
    var graphIsStripped = false
    /// Read from the production monotonic clock unless a test injects one to make deadline boundaries deterministic. A value, so passes that hold the runner `inout` can carry it.
    let deadline: ScopedDeadline

    // MARK: - Per-Cycle State

    var sources: [ScopedSource] = []
    var anyAccepted = false
    var hadUnresolvedReplacement = false
    /// True once any pass in the run accepted. Never reset: a run that ends with this false could not improve its input even once.
    var anyAcceptanceEverOccurred = false
    /// Consecutive passes that rejected every probe, across the run, for encoders behind a ``ScopedDispatchGate/demotedAfterRejects`` gate. Reset by the encoder's next acceptance.
    var consecutiveRejectsByEncoder: [EncoderName: Int] = [:]
    var sequenceBeforeCycle: ChoiceSequence = []
    /// The staged joint checkpoint last searched, so an unchanged one is not searched again.
    var exhaustedStagedJoint: ScopedStagedJointSource.Checkpoint?

    // MARK: - Coupling Attribution

    /// Value changes by pass, for attributing coupling edges between a node's last convergence and the current pass. Kept only with diagnostics.
    var valueChangeLog: [(passIndex: Int, nodeIDs: Set<Int>)] = []
    /// The pass at which each node's convergence was last recorded. Kept only with diagnostics.
    var lastConvergencePass: [Int: Int] = [:]
    /// Bounded coupling hints for joint-group ranking, kept whether or not research diagnostics are on.
    var couplingTracker = CouplingTracker()
    /// Monotonic count of applied passes.
    var passCounter = 0

    // MARK: - Step Timing

    /// When the last step timing span ended.
    var timingMark: UInt64 = 0
    /// The post-cycle bucket that every span is charged to while its pass runs.
    var timingOwner: TimingBucket?

    // MARK: - Research Diagnostics

    /// Enables floor-motion counters, coupling attribution, and the per-dispatch log. A maintainer-set literal rather than configuration, because these per-pass costs must not ride `collectStats`, which is on whenever a report is delivered.
    var collectDiagnostics = false
    /// Sequence length when the pass in flight started, for its dispatch record.
    var dispatchBaselineLength = 0
    /// Total distance to reduction targets when the pass in flight started, for its dispatch record.
    var dispatchBaselineTargetDistance: Double = 0

    // MARK: - Entry Point

    /// Reduces `output` while `property` keeps failing, and returns the reduced counterexample with the run's statistics.
    package static func reduce<Output>(
        generator: Generator<Output>,
        tree: ChoiceTree,
        output: Output,
        configuration: Configuration,
        collectStats: Bool,
        currentNanoseconds: @escaping () -> UInt64 = MonotonicClock.nanoseconds,
        property: (Output) -> Bool
    ) -> (outcome: ReductionOutcome<Output>, stats: ReductionStats) {
        withoutActuallyEscaping(property) { escapingProperty in
            var runner = ScopedReductionRunner(
                generator: generator,
                initialTree: tree,
                initialOutput: output,
                configuration: configuration,
                collectStats: collectStats,
                currentNanoseconds: currentNanoseconds,
                property: escapingProperty
            )
            runner.run()
            return runner.result()
        }
    }

    // MARK: - Setup

    /// Restores unselected branches with one exact materialization, re-encodes constant arms once, and builds the first graph.
    init<Output>(
        generator: Generator<Output>,
        initialTree: ChoiceTree,
        initialOutput: Output,
        configuration: Configuration,
        collectStats: Bool,
        currentNanoseconds: @escaping () -> UInt64 = MonotonicClock.nanoseconds,
        property: @escaping (Output) -> Bool
    ) {
        let erasedGenerator = generator.erase()
        let wrappedProperty: (Any) -> Bool = { property($0 as! Output) } // swiftlint:disable:this force_cast

        var sequence = ChoiceSequence.flatten(initialTree)
        var tree = initialTree
        var setupMaterializations = 1
        if case let .success(_, fullTree, _) = Materializer.materializeAny(
            erasedGenerator,
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
        let reencoded = ConstantArmReencoder.reencode(
            sequence: sequence,
            tree: tree,
            gen: erasedGenerator,
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
        incumbent = ScopedCounterexample(sequence: sequence, tree: tree, output: initialOutput)
        incumbentHash = ZobristHash.hash(of: sequence)
        hasBind = Self.containsBind(sequence)
        self.graph = graph
        self.generator = erasedGenerator
        self.property = wrappedProperty
        probeWrapper = configuration.probeWrapper
        tuning = configuration.tuning
        enabledEncoders = configuration.enabledEncoders
        self.collectStats = collectStats
        isInstrumented = ExhaustLog.isEnabled(.debug, for: .reducer)
        stallBudget = configuration.maxStalls
        maxStalls = configuration.maxStalls
        gate = BoundValueGate(baseBudget: configuration.tuning.boundValueBaseBudget)
        let budget = configuration.wallClockDeadlineNanoseconds
        deadline = ScopedDeadline(start: budget > 0 ? currentNanoseconds() : 0, budget: budget, clock: currentNanoseconds)

        if collectStats {
            stats.graphStats = ChoiceGraphStats.from(graph)
            stats.recordMaterializations(setupMaterializations, at: .setup)
        }

        ScopedReductionLog.reducer("graph_reducer_start", isInstrumented: isInstrumented, metadata: [
            "seq_len": "\(incumbent.sequence.count)", "max_stalls": "\(configuration.maxStalls)", "nodes": "\(graph.nodes.count)",
        ])
    }

    // MARK: - Run

    /// Runs cycles until termination or the deadline, then the final reorder pass.
    mutating func run() {
        if collectStats {
            timingMark = MonotonicClock.nanoseconds()
        }
        while true {
            guard deadline.isExpired == false else {
                finishAtDeadline()
                return
            }
            beginCycle()
            chargeElapsed(to: .untimed)
            guard deadline.isExpired == false else {
                finishAtDeadline()
                return
            }
            buildCycleSources()
            chargeElapsed(to: .buildSources)
            guard dispatchCycle() == .completed, deadline.isExpired == false else {
                finishAtDeadline()
                return
            }
            let actions = endCycle()
            chargeElapsed(to: .untimed)
            guard runPostCycleActions(actions) == .completed, deadline.isExpired == false else {
                finishAtDeadline()
                return
            }
            guard continuesAfterCycle() else {
                break
            }
        }
        runReorderPass()
        recordStallDiagnostic()
    }

    /// Whether a phase ran to its end, or the deadline cut it short and the run must finish.
    enum PhaseOutcome {
        case completed
        case deadline
    }

    // MARK: - Cycle

    private mutating func beginCycle() {
        cycles += 1
        gate.resetForNewCycle()
        // Latched across stalled cycles, so a replacement the ordering refused stays eligible for a relax round until the sequence changes.
        hadUnresolvedReplacement = hadUnresolvedReplacement && incumbent.sequence == sequenceBeforeCycle
        anyAccepted = false
        sequenceBeforeCycle = incumbent.sequence
    }

    private mutating func buildCycleSources() {
        sources = prepareAllSources(previousGraph: nil)
        ScopedReductionLog.reducer("graph_cycle_start", isInstrumented: isInstrumented, metadata: [
            "cycle": "\(cycles)", "seq_len": "\(incumbent.sequence.count)",
            "sources": "\(sources.count)", "stall_budget": "\(stallBudget)",
        ])
    }

    /// Structural families followed by value families.
    func prepareAllSources(previousGraph: ChoiceGraph?) -> [ScopedSource] {
        ScopedSource.prepareStructuralSources(from: graph, previousGraph: previousGraph)
            + ScopedSource.prepareValueSources(from: graph, tuning: tuning)
    }

    /// Rematerializes a stripped graph when pivots could follow, then evaluates the cycle and returns the enabled post-cycle actions.
    private mutating func endCycle() -> [PostCycleAction] {
        // A stripped graph has no pivot scopes.
        if anyAccepted == false, graphIsStripped, isEncoderEnabled(.branchPivot), tuning.relaxImprovingProbeBudget > 0 {
            rematerializeUnselectedBranches()
        }
        let evaluation = Self.evaluatePostCycle(
            outcome: CycleOutcome(
                anyAccepted: anyAccepted,
                hadUnresolvedReplacement: hadUnresolvedReplacement,
                // The pivot's source is spent in the cycle that probed it, so no encoder sees it in the stalled cycle and the graph has to answer.
                hasUnprobedImprovingPivot: anyAccepted == false && hasUnprobedImprovingPivot,
                allConverged: allValuesConverged(),
                improved: incumbent.sequence != sequenceBeforeCycle,
                shouldAttemptStagedJoint: anyAccepted == false && hasPendingStagedJointCheckpoint()
            ),
            stallBudget: stallBudget,
            maxStalls: maxStalls
        )
        stallBudget = evaluation.newStallBudget
        return evaluation.actions.filter(isPostCycleActionEnabled)
    }

    /// Decides whether another cycle runs, logging the cycle's end or the run's completion.
    private mutating func continuesAfterCycle() -> Bool {
        let continues = shouldRunAnotherCycle()
        if continues {
            ScopedReductionLog.reducer("graph_cycle_end", isInstrumented: isInstrumented, metadata: [
                "cycle": "\(cycles)", "improved": "\(incumbent.sequence != sequenceBeforeCycle)",
                "seq_len": "\(incumbent.sequence.count)", "total_mats": "\(stats.totalMaterializations)",
            ])
        } else if isInstrumented {
            ExhaustLog.notice(
                category: .reducer,
                event: "graph_reducer_complete",
                metadata: [
                    "cycles": "\(cycles)",
                    "seq_len": "\(incumbent.sequence.count)",
                    "total_mats": "\(stats.totalMaterializations)",
                ]
            )
        }
        return continues
    }

    /// A converged stall without structural improvement ends the run; otherwise the stall budget decides.
    private func shouldRunAnotherCycle() -> Bool {
        if incumbent.sequence.count >= sequenceBeforeCycle.count, anyAccepted == false, allValuesConverged() {
            return false
        }
        return stallBudget > 0
    }

    // MARK: - Result

    /// The reduced counterexample and the run's statistics, with the graph-level accounting folded in.
    mutating func result<Output>() -> (outcome: ReductionOutcome<Output>, stats: ReductionStats) {
        stats.graphStats.dynamicRegionRebuilds += graph.graphStats.dynamicRegionRebuilds
        stats.graphStats.dynamicRegionNodesRebuilt += graph.graphStats.dynamicRegionNodesRebuilt
        stats.cycles = cycles
        let typedOutput = incumbent.output as! Output // swiftlint:disable:this force_cast
        let outcome: ReductionOutcome<Output> = incumbent.sequence != initialSequence
            ? .reduced(incumbent.sequence, incumbent.tree, typedOutput)
            : .unreduced(incumbent.sequence, incumbent.tree, typedOutput)
        return (outcome: outcome, stats: stats)
    }

    // MARK: - Shared Helpers

    /// One eligibility rule for dispatch, post-cycle probes, and relax round exploitation.
    func isEncoderEnabled(_ name: EncoderName) -> Bool {
        enabledEncoders?.contains(name) != false
    }

    /// A decoder for the current sequence. Whether it holds a bind decides between guided and exact decoding.
    var decoder: ScopedDecoder {
        ScopedDecoder(generator: generator, property: property, probeWrapper: probeWrapper, hasBind: hasBind)
    }

    func allValuesConverged() -> Bool {
        Self.allValuesConverged(graph: graph)
    }

    /// Snapshots the sequence's length and target distance before a pass, for its dispatch record. Only with diagnostics.
    mutating func captureDispatchBaseline() {
        guard collectDiagnostics else {
            return
        }
        dispatchBaselineLength = incumbent.sequence.count
        dispatchBaselineTargetDistance = sequenceTargetDistance()
    }

    /// Sums each value's pattern-space distance to its reduction target. Floating point, because full-range leaves contribute distances near 2^63 that would overflow an integer sum.
    func sequenceTargetDistance() -> Double {
        var total: Double = 0
        for entry in incumbent.sequence {
            guard let value = entry.value else {
                continue
            }
            let bitPattern = value.choice.bitPattern64
            let target = value.choice.reductionTarget(in: value.validRange)
            let distance = bitPattern.absoluteDifference(target)
            total += Double(distance)
        }
        return total
    }

    /// Rebuilds the graph from the current tree, inheriting bind classifications and convergence records, and returns the diff that decides which sources survive.
    ///
    /// - Parameter valueGuardExemptNodeIDs: Old-graph leaves whose values are stale because they accepted a change in the pass that triggered this rebuild. Their records transfer without the value guard.
    @discardableResult
    mutating func rebuildAndUpdateGraph(valueGuardExemptNodeIDs: Set<Int> = []) -> ChoiceGraphDiff {
        stats.graphStats.dynamicRegionRebuilds += graph.graphStats.dynamicRegionRebuilds
        stats.graphStats.dynamicRegionNodesRebuilt += graph.graphStats.dynamicRegionNodesRebuilt
        let oldConvergence = Self.extractAllConvergence(from: graph, valueGuardExemptNodeIDs: valueGuardExemptNodeIDs)
        var newGraph = ChoiceGraph.build(
            from: incumbent.tree,
            inheriting: graph.bindClassifications,
            observations: graph.bindTopologyObservations,
            excludedPivots: graph.excludedPivots
        )
        newGraph.observeBindTopologies(tree: incumbent.tree)
        Self.transferConvergence(oldConvergence, to: &newGraph)
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

    /// Restores the unselected branches of a stripped tree and rebuilds the graph, so pick nodes carry every arm.
    ///
    /// - Returns: The graph before the rebuild.
    @discardableResult
    mutating func rematerializeUnselectedBranches() -> ChoiceGraph {
        if collectStats {
            stats.recordMaterializations(1, at: .rematerialization)
        }
        if case let .success(_, fullTree, _) = Materializer.materializeAny(
            generator,
            context: .init(
                prefix: incumbent.sequence,
                mode: .exact,
                fallbackTree: incumbent.tree,
                materializePicks: true
            )
        ) {
            incumbent = ScopedCounterexample(sequence: incumbent.sequence, tree: fullTree, output: incumbent.output)
        }
        let graphBefore = graph
        rebuildAndUpdateGraph()
        graphIsStripped = false
        return graphBefore
    }

    // MARK: - Helpers

    private static func containsBind(_ sequence: ChoiceSequence) -> Bool {
        sequence.contains { entry in
            guard case .bind = entry else {
                return false
            }
            return true
        }
    }
}
