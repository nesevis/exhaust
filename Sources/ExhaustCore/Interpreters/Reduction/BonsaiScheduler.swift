/// Alternating minimization over a fibred trace space: projection, base descent, fibre descent, relax-round.
///
/// **The base is the trace / the fibre is the space**:
///
/// - The **base** describes all possible ``ChoiceTree`` shapes (structure omitting concrete values).
/// A base point is a particular shape: how many choice points exist, which depend on which, and what domain each draws from.
/// - The **fibre** over a base point is the combinatorial space of values possible at that shape — the product of all possible ``ChoiceValue``s for each choice point in the tree.
/// - The **total space** is the union of all fibres across all base points: every possible (shape, values) pair that can arise from the generator.
///
/// Changing a value that no structural decision depends on stays within the same fibre. Changing a controlling value (a bind-inner position) moves to a different fibre because it changes the downstream shape.
///
/// First, a one-shot fibre projection zeros structurally independent values before the main loop begins. Then the main loop starts to reduce a failing trace by alternating between base descent (minimising the trace structure) and fibre descent (minimising the value assignment within a fixed structure) until neither makes progress. When both stall, a relax-round redistributes value magnitude speculatively and exploits the relaxed state. Then the main loop starts over.
///
/// The pipeline reads: projection → base descent → fibre descent → relax-round.
/// - **Projection** strips noise by zeroing values that no structural decision depends on.
/// - **Base descent** simplifies the structure: fewer choices, simpler branching, shorter sequences.
/// - **Fibre descent** simplifies values within the fixed structure: smaller numbers, simpler floats.
/// - **Relax-round** escapes local minima by temporarily worsening the sequence, then recovering via base and fibre descent.
enum BonsaiScheduler {
    // MARK: - Entry Point

    /// Convenience overload that materializes the output from the tree.
    static func run<Output>(
        gen: ReflectiveGenerator<Output>,
        initialTree: ChoiceTree,
        config: Interpreters.BonsaiReducerConfiguration,
        property: @escaping (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        let prefix = ChoiceSequence.flatten(initialTree)
        guard case let .success(output, _, _) = ReductionMaterializer.materialize(
            gen, prefix: prefix, mode: .exact, fallbackTree: initialTree
        ) else {
            return nil
        }
        return try run(
            gen: gen,
            initialTree: initialTree,
            initialOutput: output,
            config: config,
            property: property
        )
    }

    /// Runs the reduction pipeline to a fixed point or budget exhaustion.
    static func run<Output>(
        gen: ReflectiveGenerator<Output>,
        initialTree: ChoiceTree,
        initialOutput: Output,
        config: Interpreters.BonsaiReducerConfiguration,
        property: @escaping (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        try runCore(
            gen: gen,
            initialTree: initialTree,
            initialOutput: initialOutput,
            config: config,
            collectStats: false,
            property: property
        ).reduced
    }

    /// Runs the reduction pipeline and returns both the result and accumulated statistics.
    static func runCollectingStats<Output>(
        gen: ReflectiveGenerator<Output>,
        initialTree: ChoiceTree,
        initialOutput: Output,
        config: Interpreters.BonsaiReducerConfiguration,
        property: @escaping (Output) -> Bool
    ) throws -> (reduced: (ChoiceSequence, Output)?, stats: ReductionStats) {
        try runCore(
            gen: gen,
            initialTree: initialTree,
            initialOutput: initialOutput,
            config: config,
            collectStats: true,
            property: property
        )
    }

    private static func runCore<Output>(
        gen: ReflectiveGenerator<Output>,
        initialTree: ChoiceTree,
        initialOutput: Output,
        config: Interpreters.BonsaiReducerConfiguration,
        collectStats: Bool,
        property: @escaping (Output) -> Bool
    ) throws -> (reduced: (ChoiceSequence, Output)?, stats: ReductionStats) {
        let sequence = ChoiceSequence.flatten(initialTree)

        let state = ReductionState(
            gen: gen,
            property: property,
            config: config,
            sequence: sequence,
            tree: initialTree,
            output: initialOutput,
            initialTree: initialTree,
            collectStats: collectStats
        )

        // Branch projection: materialize with picks to get full branch alternatives,
        // then try selecting the simplest branch at every site in one batch.
        if case let .success(_, fullTree, _) = ReductionMaterializer.materialize(
            gen, prefix: state.sequence, mode: .exact, fallbackTree: initialTree,
            materializePicks: true
        ) {
            if let (result, probes) = state.branchProjectionPass.encode(
                gen: gen,
                tree: fullTree,
                sequence: state.sequence,
                property: property,
                isInstrumented: state.isInstrumented
            ) {
                if state.collectStats {
                    state.encoderProbes[.branchProjection, default: 0] += probes
                    state.totalMaterializations += probes + 1
                }
                state.accept(
                    ReductionResult(
                        sequence: result.sequence,
                        tree: result.tree,
                        output: result.output,
                        evaluations: probes,
                        decodingReport: nil
                    ),
                    structureChanged: true
                )
            } else if state.collectStats {
                state.totalMaterializations += 1
            }
        }

        // Value projection: zero structurally independent values.
        if let result = state.freeCoordinateProjectionPass.encode(
            gen: gen,
            sequence: state.sequence,
            bindIndex: state.bindIndex,
            property: property,
            isInstrumented: state.isInstrumented
        ) {
            if state.collectStats {
                state.encoderProbes[.freeCoordinateProjection, default: 0] += 1
                state.totalMaterializations += 1
            }
            state.accept(
                ReductionResult(
                    sequence: result.sequence,
                    tree: result.tree,
                    output: result.output,
                    evaluations: 1,
                    decodingReport: nil
                ),
                structureChanged: false
            )
        }

        let isInstrumented = state.isInstrumented

        var strategy = AdaptiveStrategy()
        return try runWithStrategy(
            &strategy,
            state: state,
            config: config,
            gen: gen,
            property: property,
            isInstrumented: isInstrumented
        )
    }

    /// Runs the reduction cycle loop with the given strategy.
    private static func runWithStrategy<Output>(
        _ strategy: inout some SchedulingStrategy,
        state: ReductionState<Output>,
        config: Interpreters.BonsaiReducerConfiguration,
        gen: ReflectiveGenerator<Output>,
        property: @escaping (Output) -> Bool,
        isInstrumented: Bool
    ) throws -> (reduced: (ChoiceSequence, Output)?, stats: ReductionStats) {
        var cycles = 0
        var lastOutcome: CycleOutcome?

        // MARK: - Alternating Minimisation Loop

        try runCycleLoop(
            &strategy,
            state: state,
            config: config,
            cycles: &cycles,
            lastOutcome: &lastOutcome,
            isInstrumented: isInstrumented
        )

        state.statsCycles = cycles

        // MARK: - Post-Termination Verification Sweep

        //
        // Detect stale convergence cache entries that produced a non-minimal
        // counterexample. Probe floor - 1 for each cached coordinate. If any
        // floor is stale (property fails at floor - 1), run one Phase-2-only
        // cycle with the cache cleared. Re-enter the main loop if improvements
        // found, guarded to one re-entry.

        var verificationSweepCompleted = false
        verificationSweep: do {
            let staleness = try Self.detectStaleness(state: state, gen: gen, property: property)
            state.verificationSweepProbes = staleness.probesUsed
            state.verificationSweepFoundStaleness = staleness.hasStaleFloors
            state.totalMaterializations += staleness.probesUsed
            if staleness.hasStaleFloors {
                if isInstrumented {
                    ExhaustLog.debug(
                        category: .reducer,
                        event: "verification_sweep_stale",
                        metadata: ["probes_used": "\(staleness.probesUsed)"]
                    )
                }

                // Run Phase-2-only cycle with cache cleared
                let preVerificationBest = state.bestSequence
                let savedCache = state.convergenceCache
                state.convergenceCache.invalidateAll()

                var verificationBudget = Self.computeVerificationBudget(
                    state: state, config: config
                )
                let dag = state.hasBind
                    ? ChoiceDependencyGraph.build(
                        from: state.sequence,
                        tree: state.tree,
                        bindIndex: state.bindIndex ?? BindSpanIndex(from: state.sequence)
                    )
                    : nil
                _ = try state.runFibreDescent(budget: &verificationBudget, dag: dag)

                state.convergenceCache = savedCache

                if state.bestSequence.shortLexPrecedes(preVerificationBest) {
                    // Stall was false — cache was stale. Re-enter if first time.
                    if verificationSweepCompleted == false {
                        verificationSweepCompleted = true

                        if isInstrumented {
                            ExhaustLog.debug(
                                category: .reducer,
                                event: "verification_sweep_reentry",
                                metadata: ["seq_len": "\(state.sequence.count)"]
                            )
                        }

                        // Re-enter the main reduction loop using the same strategy.
                        try runCycleLoop(
                            &strategy,
                            state: state,
                            config: config,
                            cycles: &cycles,
                            lastOutcome: &lastOutcome,
                            isInstrumented: isInstrumented
                        )

                        // Check for staleness again after re-entry
                        let secondStaleness = try Self.detectStaleness(
                            state: state, gen: gen, property: property
                        )
                        if secondStaleness.hasStaleFloors {
                            ExhaustLog.debug(
                                category: .reducer,
                                event: "systematic_cache_staleness",
                                metadata: ["probes_used": "\(secondStaleness.probesUsed)"]
                            )
                        }
                    }
                }
            }
        }

        if isInstrumented, let instrumentation = state.convergenceInstrumentation {
            let records = instrumentation.records
            let totalConvergences = instrumentation.totalEncoderConvergences

            // Stability: for each coordinate, compare converged values across consecutive cycles.
            var stabilityMatches = 0
            var stabilityPairs = 0
            let byCycle = Dictionary(grouping: records, by: { $0.cycle })
            let sortedCycles = byCycle.keys.sorted()
            for index in sortedCycles.indices.dropFirst() {
                let previousCycle = sortedCycles[index - 1]
                let currentCycle = sortedCycles[index]
                guard let previousRecords = byCycle[previousCycle],
                      let currentRecords = byCycle[currentCycle]
                else {
                    continue
                }
                let previousByIndex = Dictionary(
                    previousRecords.map { ($0.coordinateIndex, $0.convergedValue) },
                    uniquingKeysWith: { _, last in last }
                )
                for record in currentRecords {
                    if let previousValue = previousByIndex[record.coordinateIndex] {
                        stabilityPairs += 1
                        let delta = record.convergedValue > previousValue
                            ? record.convergedValue - previousValue
                            : previousValue - record.convergedValue
                        if delta <= 1 {
                            stabilityMatches += 1
                        }
                    }
                }
            }
            let convergenceStability = stabilityPairs > 0
                ? Double(stabilityMatches) / Double(stabilityPairs)
                : 0

            ExhaustLog.notice(
                category: .reducer,
                event: "convergence_instrumentation",
                metadata: [
                    "total_convergences": "\(totalConvergences)",
                    "convergence_stability": String(format: "%.3f", convergenceStability),
                    "stability_pairs": "\(stabilityPairs)",
                    "cycles": "\(cycles)",
                ]
            )
        }

        if isInstrumented {
            ExhaustLog.notice(
                category: .reducer,
                event: "bonsai_complete",
                metadata: ["cycles": "\(cycles)"]
            )
        }

        var bestSequence = state.bestSequence
        var bestOutput = state.bestOutput

        if let humanResult = state.humanReadableOrderingPass.encode(
            gen: gen,
            sequence: bestSequence,
            tree: state.tree,
            property: property
        ) {
            if state.collectStats {
                state.encoderProbes[.humanOrderReorder, default: 0] +=
                    humanResult.materializations
                state.totalMaterializations += humanResult.materializations
            }
            bestSequence = humanResult.result.sequence
            bestOutput = humanResult.result.output
            if isInstrumented {
                ExhaustLog.notice(category: .reducer, event: "human_order_accepted")
            }
        }

        return (reduced: (bestSequence, bestOutput), stats: state.extractStats())
    }

    // MARK: - Phase Dispatch

    /// Dispatches a single planned phase to the appropriate ``ReductionState`` method.
    ///
    /// Returns the phase outcome and optionally the CDG produced by base descent (other phases return nil for the DAG).
    private static func dispatchPhase(
        _ planned: PlannedPhase,
        state: ReductionState<some Any>,
        dag: ChoiceDependencyGraph?
    ) throws -> (outcome: PhaseOutcome, dag: ChoiceDependencyGraph?) {
        switch planned.phase {
        case .baseDescent:
            var budget = planned.budget
            let (producedDag, _) = try state.runBaseDescent(
                budget: &budget, cycle: state.currentCycle,
                scopeRange: planned.configuration.scopeRange
            )
            let baseOutcome = state.phaseTracker.outcome(
                for: .baseDescent, budgetAllocated: planned.budget
            )
            return (baseOutcome, producedDag)

        case .fibreDescent:
            var budget = planned.budget
            if planned.configuration.clearConvergence {
                state.convergenceCache.invalidateAll()
            }
            _ = try state.runFibreDescent(
                budget: &budget,
                dag: dag,
                scopeRange: planned.configuration.scopeRange
            )

            let fibreOutcome = state.phaseTracker.outcome(
                for: .fibreDescent, budgetAllocated: planned.budget
            )
            return (fibreOutcome, nil)

        case .exploration:
            var budget = planned.budget
            _ = try state.runKleisliExploration(
                budget: &budget,
                dag: dag,
                edgeBudgetPolicy: planned.configuration.edgeBudgetPolicy,
                scopeRange: planned.configuration.scopeRange
            )
            let exploreOutcome = state.phaseTracker.outcome(
                for: .exploration, budgetAllocated: planned.budget
            )
            return (exploreOutcome, nil)

        case .relaxRound:
            var budget = planned.budget
            _ = try state.runRelaxRound(remaining: &budget)
            let relaxOutcome = state.phaseTracker.outcome(
                for: .relaxRound, budgetAllocated: planned.budget
            )
            return (relaxOutcome, nil)

        }
    }

    // MARK: - Cycle Execution

    /// Runs a single reduction cycle: encoder ordering, first stage, second stage, outcome collection.
    ///
    /// Returns the cycle outcome with per-phase disposition data for strategy feedback and statistics.
    private static func runSingleCycle(
        _ strategy: inout some SchedulingStrategy,
        state: ReductionState<some Any>,
        lastOutcome: CycleOutcome?,
        isInstrumented: Bool
    ) throws -> CycleOutcome {
        let cycleStartBest = state.bestSequence
        state.computeEncoderOrdering()

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "bonsai_cycle_start",
                metadata: [
                    "cycle": "\(state.currentCycle)",
                    "seq_len": "\(state.sequence.count)",
                ]
            )
        }

        var dag: ChoiceDependencyGraph? = state.buildDAG()

        // Stage 1: phases that run unconditionally (structural minimization).
        let firstStagePhases = strategy.planFirstStage(
            priorOutcome: lastOutcome,
            state: state.view
        )
        var cycleImproved = false
        var phaseDispositions: [PlannedPhase.Phase: PhaseDisposition] = [:]

        var firstStageResult: PhaseOutcome?
        for planned in firstStagePhases {
            let (outcome, producedDag) = try Self.dispatchPhase(planned, state: state, dag: dag)
            dag = producedDag ?? dag
            if outcome.acceptances > 0 { cycleImproved = true }
            strategy.phaseCompleted(phase: planned.phase, outcome: outcome)
            firstStageResult = outcome
            phaseDispositions[planned.phase] = .ran(outcome)
        }

        // Stage 2: phases that depend on stage 1 results (fibre descent, exploration, relax-round).
        let secondStagePhases = strategy.planSecondStage(
            firstStageResult: firstStageResult,
            state: state.view
        )
        for planned in secondStagePhases {
            if planned.requiresStall, cycleImproved {
                phaseDispositions[planned.phase] = .gated(reason: .noProgress)
                continue
            }

            let (outcome, _) = try Self.dispatchPhase(planned, state: state, dag: dag)
            if outcome.acceptances > 0 { cycleImproved = true }
            strategy.phaseCompleted(phase: planned.phase, outcome: outcome)
            phaseDispositions[planned.phase] = .ran(outcome)
        }

        // Mark phases that were not in either stage as gated.
        let allPhases: [PlannedPhase.Phase] = [
            .baseDescent, .fibreDescent, .exploration, .relaxRound,
        ]
        for phase in allPhases where phaseDispositions[phase] == nil {
            let reason: GateReason =
                phase == .fibreDescent
                    ? .allCoordinatesConverged
                    : .noProgress
            phaseDispositions[phase] = .gated(reason: reason)
        }

        let outcome = CycleOutcome(
            baseDescent: phaseDispositions[.baseDescent] ?? .gated(reason: .noProgress),
            fibreDescent: phaseDispositions[.fibreDescent] ?? .gated(reason: .noProgress),
            exploration: phaseDispositions[.exploration] ?? .gated(reason: .noProgress),
            relaxRound: phaseDispositions[.relaxRound] ?? .gated(reason: .noProgress),
            zeroingDependencyCount: state.zeroingDependencyCount,
            monotoneConvergenceCount: 0,
            exhaustedCleanEdges: state.fibreExhaustedCleanCount,
            exhaustedWithFailureEdges: state.fibreExhaustedWithFailureCount,
            totalEdges: state.compositionEdgesAttempted,
            improved: state.bestSequence.shortLexPrecedes(cycleStartBest),
            cycle: state.currentCycle
        )

        if state.collectStats {
            state.statsCycleOutcomes.append(outcome)
            state.phaseTracker.reset()
        }

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "bonsai_cycle_end",
                metadata: [
                    "cycle": "\(state.currentCycle)",
                    "improved": "\(cycleImproved)",
                    "seq_len": "\(state.sequence.count)",
                ]
            )
        }

        return outcome
    }

    /// Runs reduction cycles until stall budget is exhausted.
    private static func runCycleLoop(
        _ strategy: inout some SchedulingStrategy,
        state: ReductionState<some Any>,
        config: Interpreters.BonsaiReducerConfiguration,
        cycles: inout Int,
        lastOutcome: inout CycleOutcome?,
        isInstrumented: Bool
    ) throws {
        var stallBudget = config.maxStalls
        while stallBudget > 0 {
            cycles += 1
            state.currentCycle = cycles
            let outcome = try runSingleCycle(
                &strategy,
                state: state,
                lastOutcome: lastOutcome,
                isInstrumented: isInstrumented
            )
            lastOutcome = outcome
            if outcome.improved {
                stallBudget = config.maxStalls
            } else {
                // All value coordinates converged and no progress — the CE is at
                // a fixed point. Exit immediately instead of burning stall budget.
                if state.allValueCoordinatesConverged() {
                    break
                }
                stallBudget -= 1
            }
        }
    }

    // MARK: - Post-Termination Verification Helpers

    /// Result of probing `floor - 1` for each cached convergence point.
    struct StalenessCheck {
        let hasStaleFloors: Bool
        let probesUsed: Int
    }

    /// Probes `floor - 1` for each cached convergence point to detect stale floors.
    ///
    /// Returns on first stale detection (property fails at `floor - 1`). Skips trivially valid floors (at range minimum). Accepts the result if it shortLexPrecedes the current sequence.
    static func detectStaleness<Output>(
        state: ReductionState<Output>,
        gen: ReflectiveGenerator<Output>,
        property: @escaping (Output) -> Bool
    ) throws -> StalenessCheck {
        var probesUsed = 0
        for index in 0 ..< state.sequence.count {
            guard let value = state.sequence[index].value,
                  let origin = state.convergenceCache.convergedOrigin(at: index),
                  let range = value.validRange
            else { continue }

            let floorBitPattern = origin.bound
            guard floorBitPattern > range.lowerBound else { continue }

            let probeBitPattern = floorBitPattern - 1
            var candidate = state.sequence
            candidate[index] = .value(.init(
                choice: ChoiceValue(
                    value.choice.tag.makeConvertible(bitPattern64: probeBitPattern),
                    tag: value.choice.tag
                ),
                validRange: value.validRange,
                isRangeExplicit: value.isRangeExplicit
            ))

            probesUsed += 1
            let decoder = SequenceDecoder.exact()
            if let result = try decoder.decode(
                candidate: candidate,
                gen: gen,
                tree: state.tree,
                originalSequence: state.sequence,
                property: property
            ) {
                if result.sequence.shortLexPrecedes(state.sequence) {
                    state.accept(result, structureChanged: false)
                    return StalenessCheck(hasStaleFloors: true, probesUsed: probesUsed)
                }
            }
        }
        return StalenessCheck(hasStaleFloors: false, probesUsed: probesUsed)
    }

    /// Default budget for the verification cycle's value minimization pass.
    static let verificationBudget = 975

    /// Computes the verification cycle budget based on the user's reduction budget.
    ///
    /// `.fast` (maxStalls ≤ 1): standard budget (best-effort). `.slow`: expanded budget based on per-coordinate range sizes.
    static func computeVerificationBudget(
        state: ReductionState<some Any>,
        config: Interpreters.BonsaiReducerConfiguration
    ) -> Int {
        if config.maxStalls <= 1 {
            return verificationBudget
        }
        var budget = 0
        for index in 0 ..< state.sequence.count {
            guard let value = state.sequence[index].value,
                  let range = value.validRange
            else { continue }
            let rangeSpan = range.upperBound - range.lowerBound
            let rangeSize = rangeSpan == UInt64.max ? UInt64.max : rangeSpan + 1
            // ceil(log2(rangeSize)) via bit width — no floating-point
            let bitsNeeded = UInt64.bitWidth - max(2, rangeSize - 1).leadingZeroBitCount
            budget += bitsNeeded
        }
        return max(budget, verificationBudget)
    }
}
