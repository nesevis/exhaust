/// Bonsai cultivation cycle scheduler for principled test case reduction.
///
/// Orchestrates encoders and decoders in the cultivation cycle: snip (contravariant sweep, depths max→1, exact), prune (deletion sweep, depths 0→max, guided), train (covariant sweep, depth 0, guided for binds), and shape (redistribution).
///
/// Resource tracking uses per-leg budgets with unused-budget forwarding. Each leg has a hard cap (maximum materializations) and a stall patience (maximum consecutive fruitless materializations). Forwarded budget extends productive legs but does not increase patience for unproductive ones.
///
/// Encoder ordering within each leg uses move-to-front: when an encoder succeeds, it is promoted to the front of its leg's order for subsequent iterations. This adapts to generator structure without parameters — productive encoders are tried first, reducing wasted materializations on consistently fruitless encoders.
enum ReductionScheduler {
    // MARK: - Entry Point

    /// Runs the V-cycle reduction to a fixed point or budget exhaustion.
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

        let isInstrumented = state.isInstrumented
        var stallBudget = config.maxStalls
        var cyclesSinceRedistribution = 0
        let redistributionDeferralCap = 3
        var cycles = 0

        // MARK: - V-Cycle
        //
        // Each leg internally uses nondeterministic encoders (Kleisli arrows
        // X → P(X) producing candidate sets), but resolves to a single best
        // candidate before the next leg starts. The cycle is therefore
        // deterministic composition in Set:
        //
        //   resolve ∘ leg_n ∘ ... ∘ resolve ∘ leg_1
        //
        // not Kleisli composition in Kl(P):
        //
        //   leg_n ⊙ ... ⊙ leg_1
        //
        // Full Kleisli composition would explore all paths through the
        // candidate sets of every leg (exponential in the number of legs and
        // accepted candidates per leg) and pick the globally optimal endpoint.
        // Greedy resolution is sound (each step is exact, so the composite
        // is exact) but incomplete — it can miss better endpoints reachable
        // through intermediate candidates that are suboptimal for one leg but
        // unlock improvements in a later leg.
        //
        // With 5 legs and 5–20 accepted candidates per leg, full Kleisli
        // composition would require 5^5 to 20^5 property evaluations per
        // cycle. The reducer typically completes in 30–800 total evaluations.
        // Greedy resolution (k=1) is the only viable operating point.
        //
        // See: Sepúlveda-Jiménez, "Categories of Optimization Reductions"
        // (Jan 2026), Section 7.3 (Def 7.7, Prop 7.8) for the Kleisli
        // composition framework and its cost guarantees.

        while stallBudget > 0 {
            cycles += 1
            let cycleStartBest = state.bestSequence
            var cycleImproved = false
            let maxBindDepth = state.bindIndex?.maxBindDepth ?? 0
            var dirtyDepths = Set(0 ... maxBindDepth)
            var remaining = state.cycleBudget.total

            state.computeEncoderOrdering()

            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "vcycle_start",
                    metadata: ["cycle": "\(cycles)", "stall_budget": "\(stallBudget)", "max_bind_depth": "\(maxBindDepth)", "cycle_budget": "\(remaining)"]
                )
            }

            // ── Pre-cycle: Branch ──
            if try state.runBranchLeg(remaining: &remaining) {
                cycleImproved = true
            }

            // ── Leg 1: Snip — contravariant sweep (depths max → 1) ──
            let contravariantAccepted = try state.runSnipLeg(
                remaining: &remaining,
                maxBindDepth: maxBindDepth,
                dirtyDepths: dirtyDepths
            )

            // ── Leg 2: Prune — deletion sweep (depths 0 → max) ──
            let deletionAccepted = try state.runPruneLeg(
                remaining: &remaining,
                maxBindDepth: maxBindDepth
            )
            if deletionAccepted > 0 {
                cycleImproved = true
                dirtyDepths = Set(0 ... (state.bindIndex?.maxBindDepth ?? 0))
            }

            // ── Leg 3: Train — covariant sweep (depth 0) ──
            let covariantAccepted = try state.runTrainLeg(remaining: &remaining)
            if covariantAccepted > 0 {
                cycleImproved = true
                dirtyDepths = Set(0 ... (state.bindIndex?.maxBindDepth ?? 0))
            }

            // ── Cross-cutting: Redistribution ──
            let mainLegsStalled = contravariantAccepted == 0 && deletionAccepted == 0
            let redistributionOverdue = cyclesSinceRedistribution >= redistributionDeferralCap
            let redistributionTriggered = mainLegsStalled || redistributionOverdue

            if redistributionTriggered {
                cyclesSinceRedistribution = 0
                if try state.runRedistributionLeg(remaining: &remaining) {
                    cycleImproved = true
                }
            } else {
                cyclesSinceRedistribution += 1
            }

            // ── Cycle termination ──
            let cycleProbes = state.cycleBudget.total - remaining
            if state.bestSequence.count < cycleStartBest.count || state.bestSequence.shortLexPrecedes(cycleStartBest) {
                stallBudget = config.maxStalls
            } else {
                stallBudget -= 1
            }
            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "vcycle_end",
                    metadata: [
                        "cycle": "\(cycles)",
                        "probes": "\(cycleProbes)",
                        "improved": "\(cycleImproved)",
                        "seq_len": state.sequence.count.description,
                        "deletion": "\(deletionAccepted)",
                        "contravariant": "\(contravariantAccepted)",
                        "covariant": "\(covariantAccepted)",
                        "cached_total": state.rejectCache.count.description
                    ]
                )
            }
        }

        if isInstrumented {
            ExhaustLog.notice(category: .reducer, event: "vcycle_complete", metadata: ["cycles": "\(cycles)"])
        }

        var bestSequence = state.bestSequence
        var bestOutput = state.bestOutput

        if config.humanOrderPostProcess {
            if let humanResult = Self.humanOrderPostProcess(
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
