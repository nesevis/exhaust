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
    // MARK: - Budget Constants

    // Empirically tuned on the shrinking challenge suite (March 2026).
    // Ratio 6:3:1 reflects that structural changes (base descent) unlock
    // more downstream value reduction than value changes alone, while
    // the relax-round is speculative and should consume minimal budget.
    // The total per-cycle budget (~3250 evaluations) balances reduction
    // quality against wall-clock time for typical generators.

    /// Per-round budget for base descent (structural minimization).
    static let baseDescentBudget = 1950

    /// Per-round budget for fibre descent (value minimization).
    static let fibreDescentBudget = 975

    /// Per-round budget for the relax-round when neither descent phase makes progress.
    static let relaxRoundBudget = 325

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

        // Projection: zero structurally independent values.
        if let result = StructuralIsolator.project(
            gen: gen,
            sequence: state.sequence,
            bindIndex: state.bindIndex,
            property: property,
            isInstrumented: state.isInstrumented
        ) {
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
        var stallBudget = config.maxStalls
        var cycles = 0
        var previousFibreProgress = true // assume progress before cycle 1

        // MARK: - Alternating Minimisation Loop

        while stallBudget > 0 {
            cycles += 1
            state.currentCycle = cycles
            let cycleStartBest = state.bestSequence

            state.computeEncoderOrdering()

            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "bonsai_cycle_start",
                    metadata: [
                        "cycle": "\(cycles)",
                        "stall_budget": "\(stallBudget)",
                        "seq_len": "\(state.sequence.count)",
                    ]
                )
            }

            // Base descent: simplify the trace structure.
            var baseRemaining = Self.baseDescentBudget
            let (dag, baseProgress) = try state.runBaseDescent(budget: &baseRemaining, cycle: cycles)

            // Fibre descent gating (signal 4): skip when all value coordinates are at
            // cached floors, base descent made no structural progress, AND Phase 2 made
            // no progress in the previous cycle. The stall condition prevents skipping
            // when cross-zero or ZeroValue can still improve beyond cached binary search floors.
            let fibreProgress: Bool
            var fibreGated = false
            if baseProgress == false,
               previousFibreProgress == false,
               cycles > 1,
               state.allValueCoordinatesConverged()
            {
                fibreProgress = false
                fibreGated = true
                if state.isInstrumented {
                    ExhaustLog.debug(
                        category: .reducer,
                        event: "fibre_descent_gated",
                        metadata: ["cycle": "\(cycles)"]
                    )
                }
            } else {
                var fibreRemaining = Self.fibreDescentBudget
                fibreProgress = try state.runFibreDescent(budget: &fibreRemaining, dag: dag)
            }
            previousFibreProgress = fibreProgress

            // Exploration: if neither descent made progress, try cross-level and same-level minima.
            var cycleImproved = baseProgress || fibreProgress
            var kleisliRan = false
            var relaxRan = false
            if cycleImproved == false {
                // Kleisli exploration: cross-level minima via dependency edge composition.
                kleisliRan = true
                var kleisliRemaining = Self.relaxRoundBudget
                if try state.runKleisliExploration(budget: &kleisliRemaining, dag: dag) {
                    cycleImproved = true
                }

                // Relax-round: same-level minima via value redistribution.
                if cycleImproved == false {
                    relaxRan = true
                    var relaxRemaining = Self.relaxRoundBudget
                    if try state.runRelaxRound(remaining: &relaxRemaining) {
                        cycleImproved = true
                    }
                }
            }

            // Stall detection.
            if state.bestSequence.shortLexPrecedes(cycleStartBest) {
                stallBudget = config.maxStalls
            } else {
                stallBudget -= 1
            }

            // Collect per-phase outcome data.
            if state.collectStats {
                state.statsCycleOutcomes.append(CycleOutcome(
                    baseDescent: .ran(state.phaseTracker.outcome(for: .baseDescent, budgetAllocated: Self.baseDescentBudget)),
                    fibreDescent: fibreGated
                        ? .gated(reason: .allCoordinatesConverged)
                        : .ran(state.phaseTracker.outcome(for: .fibreDescent, budgetAllocated: Self.fibreDescentBudget)),
                    exploration: kleisliRan
                        ? .ran(state.phaseTracker.outcome(for: .exploration, budgetAllocated: Self.relaxRoundBudget))
                        : .gated(reason: .noProgress),
                    relaxRound: relaxRan
                        ? .ran(state.phaseTracker.outcome(for: .relaxRound, budgetAllocated: Self.relaxRoundBudget))
                        : .gated(reason: .noProgress),
                    zeroingDependencyCount: state.zeroingDependencyCount,
                    monotoneConvergenceCount: 0,
                    exhaustedCleanEdges: state.fibreExhaustedCleanCount,
                    exhaustedWithFailureEdges: state.fibreExhaustedWithFailureCount,
                    totalEdges: state.compositionEdgesAttempted,
                    improved: state.bestSequence.shortLexPrecedes(cycleStartBest),
                    cycle: cycles
                ))
                state.phaseTracker.reset()
            }

            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "bonsai_cycle_end",
                    metadata: [
                        "cycle": "\(cycles)",
                        "improved": "\(cycleImproved)",
                        "base_descent": "\(baseProgress)",
                        "fibre_descent": "\(fibreProgress)",
                        "seq_len": "\(state.sequence.count)",
                    ]
                )
            }
        }

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
                        stallBudget = config.maxStalls

                        if isInstrumented {
                            ExhaustLog.debug(
                                category: .reducer,
                                event: "verification_sweep_reentry",
                                metadata: ["seq_len": "\(state.sequence.count)"]
                            )
                        }

                        // Re-enter the main reduction loop
                        while stallBudget > 0 {
                            cycles += 1
                            state.currentCycle = cycles
                            let cycleStartBest = state.bestSequence

                            state.computeEncoderOrdering()

                            var baseRemaining = Self.baseDescentBudget
                            let (dag, baseProgress) = try state.runBaseDescent(
                                budget: &baseRemaining, cycle: cycles
                            )

                            var fibreRemaining = Self.fibreDescentBudget
                            let fibreProgress = try state.runFibreDescent(
                                budget: &fibreRemaining, dag: dag
                            )

                            var cycleImproved = baseProgress || fibreProgress
                            if cycleImproved == false {
                                var kleisliRemaining = Self.relaxRoundBudget
                                if try state.runKleisliExploration(
                                    budget: &kleisliRemaining, dag: dag
                                ) {
                                    cycleImproved = true
                                }

                                if cycleImproved == false {
                                    var relaxRemaining = Self.relaxRoundBudget
                                    if try state.runRelaxRound(remaining: &relaxRemaining) {
                                        cycleImproved = true
                                    }
                                }
                            }

                            if state.bestSequence.shortLexPrecedes(cycleStartBest) {
                                stallBudget = config.maxStalls
                            } else {
                                stallBudget -= 1
                            }
                        }

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
            ExhaustLog.notice(category: .reducer, event: "bonsai_complete", metadata: ["cycles": "\(cycles)"])
        }

        var bestSequence = state.bestSequence
        var bestOutput = state.bestOutput

        if config.humanOrderPostProcess {
            if let humanResult = ReductionScheduler.humanOrderPostProcess(
                gen: gen,
                sequence: bestSequence,
                tree: state.tree,
                property: property
            ) {
                bestSequence = humanResult.sequence
                bestOutput = humanResult.output
                if isInstrumented {
                    ExhaustLog.notice(category: .reducer, event: "human_order_accepted")
                }
            }
        }

        return (reduced: (bestSequence, bestOutput), stats: state.extractStats())
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

            let floorBP = origin.bound
            guard floorBP > range.lowerBound else { continue }

            let probeBP = floorBP - 1
            var candidate = state.sequence
            candidate[index] = .value(.init(
                choice: ChoiceValue(
                    value.choice.tag.makeConvertible(bitPattern64: probeBP),
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

    /// Computes the verification cycle budget based on the user's reduction budget.
    ///
    /// `.fast` (maxStalls ≤ 1): standard Phase-2 budget (best-effort). `.slow`: expanded budget based on per-coordinate range sizes.
    static func computeVerificationBudget<Output>(
        state: ReductionState<Output>,
        config: Interpreters.BonsaiReducerConfiguration
    ) -> Int {
        if config.maxStalls <= 1 {
            return fibreDescentBudget
        }
        var budget = 0
        for index in 0 ..< state.sequence.count {
            guard let value = state.sequence[index].value,
                  let range = value.validRange
            else { continue }
            let rangeSize = range.upperBound - range.lowerBound + 1
            // ceil(log2(rangeSize)) via bit width — no floating-point
            let bitsNeeded = UInt64.bitWidth - max(2, rangeSize - 1).leadingZeroBitCount
            budget += bitsNeeded
        }
        return max(budget, fibreDescentBudget)
    }
}
