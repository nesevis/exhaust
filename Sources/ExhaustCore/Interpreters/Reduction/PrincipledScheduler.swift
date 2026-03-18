/// Two-phase reduction scheduler: structural minimization with restart-on-success, then DAG-guided value minimization.
///
/// Replaces the V-cycle's interleaved legs with a clean two-phase pipeline. Phase 1 (structural minimization) runs branch, deletion, and joint bind-inner encoders with a restart-on-success policy. Phase 2 (value minimization) processes only DAG leaf positions, guarded by a ``SkeletonFingerprint`` check to detect accidental structural changes. The two phases alternate until neither makes progress.
enum PrincipledScheduler {
    // MARK: - Budget Constants

    /// Per-round budget for structural minimization (Phase 1).
    static let phase1Budget = 1950

    /// Per-round budget for value minimization (Phase 2).
    static let phase2Budget = 975

    /// Per-round budget for speculation when neither phase makes progress.
    static let speculationBudget = 325

    // MARK: - Entry Point

    /// Runs the two-phase reduction to a fixed point or budget exhaustion.
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

        // Phase 0: Structural Independence Isolation
        if let result = StructuralIsolation.isolate(
            gen: gen,
            sequence: state.sequence,
            tree: state.tree,
            bindIndex: state.bindIndex,
            property: property,
            isInstrumented: state.isInstrumented
        ) {
            state.accept(
                ShrinkResult(
                    sequence: result.sequence,
                    tree: result.tree,
                    output: result.output,
                    evaluations: 1
                ),
                structureChanged: false
            )
        }

        let isInstrumented = state.isInstrumented
        var stallBudget = config.maxStalls
        var cycles = 0

        // MARK: - Two-Phase Outer Loop

        while stallBudget > 0 {
            cycles += 1
            let cycleStartBest = state.bestSequence

            state.computeEncoderOrdering()

            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "principled_cycle_start",
                    metadata: [
                        "cycle": "\(cycles)",
                        "stall_budget": "\(stallBudget)",
                        "seq_len": "\(state.sequence.count)",
                    ]
                )
            }

            // Phase 1: Structural minimization with restart-on-success.
            var phase1Remaining = Self.phase1Budget
            let (dag, phase1Progress) = try state.runStructuralMinimization(budget: &phase1Remaining)

            // Phase 2: Value minimization on DAG leaves.
            var phase2Remaining = Self.phase2Budget
            let phase2Progress = try state.runValueMinimization(budget: &phase2Remaining, dag: dag)

            // Speculation: if neither phase made progress, try speculative exploration.
            var cycleImproved = phase1Progress || phase2Progress
            if cycleImproved == false {
                var specRemaining = Self.speculationBudget
                if try state.runExplorationLeg(remaining: &specRemaining) {
                    cycleImproved = true
                }
            }

            // Stall detection.
            if state.bestSequence.count < cycleStartBest.count
                || state.bestSequence.shortLexPrecedes(cycleStartBest)
            {
                stallBudget = config.maxStalls
            } else {
                stallBudget -= 1
            }

            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "principled_cycle_end",
                    metadata: [
                        "cycle": "\(cycles)",
                        "improved": "\(cycleImproved)",
                        "phase1": "\(phase1Progress)",
                        "phase2": "\(phase2Progress)",
                        "seq_len": "\(state.sequence.count)",
                    ]
                )
            }
        }

        if isInstrumented {
            ExhaustLog.notice(category: .reducer, event: "principled_complete", metadata: ["cycles": "\(cycles)"])
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
