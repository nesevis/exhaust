/// Alternating minimisation over a fibred trace space: projection, base descent, fibre descent, relax-round.
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

    /// Per-round budget for base descent (structural minimisation).
    static let baseDescentBudget = 1950

    /// Per-round budget for fibre descent (value minimisation).
    static let fibreDescentBudget = 975

    /// Per-round budget for the relax-round when neither descent phase makes progress.
    static let relaxRoundBudget = 325

    // MARK: - Entry Point

    /// Runs the reduction pipeline to a fixed point or budget exhaustion.
    static func run<Output>(
        gen: ReflectiveGenerator<Output>,
        initialTree: ChoiceTree,
        config: Interpreters.BonsaiReducerConfiguration,
        property: @escaping (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        let sequence = ChoiceSequence.flatten(initialTree)
        let tree = initialTree
        guard let output = try Interpreters.materialize(gen, with: tree, using: sequence) else {
            return nil
        }

        let state = ReductionState(
            gen: gen,
            property: property,
            config: config,
            sequence: sequence,
            tree: tree,
            output: output,
            initialTree: initialTree
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

            // Fibre descent: simplify values within the fixed structure.
            var fibreRemaining = Self.fibreDescentBudget
            let fibreProgress = try state.runFibreDescent(budget: &fibreRemaining, dag: dag)

            // Relax-round: if neither descent made progress, redistribute and exploit.
            var cycleImproved = baseProgress || fibreProgress
            if cycleImproved == false {
                var relaxRemaining = Self.relaxRoundBudget
                if try state.runRelaxRound(remaining: &relaxRemaining) {
                    cycleImproved = true
                }
            }

            // Stall detection.
            if state.bestSequence.shortLexPrecedes(cycleStartBest) {
                stallBudget = config.maxStalls
            } else {
                stallBudget -= 1
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
                useReductionMaterializer: config.useReductionMaterializer,
                property: property
            ) {
                bestSequence = humanResult.sequence
                bestOutput = humanResult.output
                if isInstrumented {
                    ExhaustLog.notice(category: .reducer, event: "human_order_accepted")
                }
            }
        }

        return (bestSequence, bestOutput)
    }
}
