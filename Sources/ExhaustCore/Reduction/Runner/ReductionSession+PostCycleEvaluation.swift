//
//  ReductionSession+PostCycleEvaluation.swift
//  Exhaust
//

// MARK: - Post-Cycle Evaluation

extension ReductionSession {
    /// What happened during one cycle, for deciding what follows it.
    struct CycleOutcome {
        let anyAccepted: Bool
        /// Latched across stalled cycles until the sequence changes.
        let hadUnresolvedReplacement: Bool
        let hasUnprobedImprovingPivot: Bool
        let allConverged: Bool
        let improved: Bool
        let shouldAttemptStagedJoint: Bool
    }

    /// Work that may follow a cycle. Termination is not an action: it depends on state these actions change, since a relax round can improve the sequence, confirmation can recover smaller failures, and a relation acceptance re-enters the loop.
    enum PostCycleAction: Equatable {
        /// Probes toward each converged leaf's target and retains the first smaller failing counterexample.
        case confirmConvergence
        /// Reduces pairs of stalled leaves along the rational relation inferred from their current values: holds the ratio fixed and lowers the shared scale, so (6, 9) tries (2, 3) first, for multiplicative couplings that per-leaf, lockstep, and redistribution moves cannot preserve.
        case relationPass
        /// Probes branch pivots at non-minimal content and accepts the first that still fails, without a checkpoint.
        case improvingPivots
        /// Searches the pending staged joint checkpoint, trying sign flips and samples for selected pairs and wider groups.
        case stagedJointPass
        /// Perturbs the counterexample with a structural replacement that may worsen it, exploits it, and keeps the result only if it strictly precedes the checkpoint.
        case relaxRound
    }

    /// The actions to attempt, in order, with the loop control values that follow from the cycle.
    struct PostCycleEvaluation: Equatable {
        let actions: [PostCycleAction]
        let newStallBudget: Int
    }

    /// Decides what follows a cycle from its outcome, the stall budget, and max stalls.
    static func evaluatePostCycle(
        outcome: CycleOutcome,
        stallBudget: Int,
        maxStalls: Int
    ) -> PostCycleEvaluation {
        var actions: [PostCycleAction] = []

        if outcome.anyAccepted == false, outcome.allConverged {
            actions.append(.confirmConvergence)
            // Relation search runs after confirmation: value search writes convergence records mid-cycle, so on a run that stalls in its first cycle nothing would rebuild a source that could see them. Here, with everything converged and nothing accepted, the stall is visible and the relation pass can act on it.
            actions.append(.relationPass)
        }

        if outcome.anyAccepted == false, outcome.hasUnprobedImprovingPivot {
            actions.append(.improvingPivots)
        }

        if outcome.anyAccepted == false, outcome.shouldAttemptStagedJoint {
            actions.append(.stagedJointPass)
        }

        let newStallBudget = outcome.improved ? maxStalls : stallBudget - 1

        // The relax round worsens shortlex before it can improve, so it waits for the stall that would otherwise end the run. A converged stall ends the run whatever budget remains.
        if outcome.anyAccepted == false,
           outcome.hadUnresolvedReplacement,
           newStallBudget <= 0 || outcome.allConverged
        {
            actions.append(.relaxRound)
        }

        return PostCycleEvaluation(
            actions: actions,
            newStallBudget: newStallBudget
        )
    }

    /// Filters post-cycle actions by encoder eligibility.
    func isPostCycleActionEnabled(_ action: PostCycleAction) -> Bool {
        switch action {
            case .confirmConvergence:
                isEncoderEnabled(.convergenceConfirmation)
            case .relationPass:
                isEncoderEnabled(.relationSearch)
            case .improvingPivots:
                isEncoderEnabled(.branchPivot)
            case .stagedJointPass:
                isEncoderEnabled(.stagedJointSearch)
            case .relaxRound:
                isEncoderEnabled(.branchPivot) || isEncoderEnabled(.substitution)
        }
    }
}
