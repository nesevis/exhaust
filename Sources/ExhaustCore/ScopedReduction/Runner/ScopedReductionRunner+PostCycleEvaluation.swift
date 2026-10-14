//
//  ScopedReductionRunner+PostCycleEvaluation.swift
//  Exhaust
//

// MARK: - Post-Cycle Evaluation

extension ScopedReductionRunner {
    /// What happened during one cycle, for deciding what follows it.
    struct CycleOutcome {
        let anyAccepted: Bool
        /// Latched across stalled cycles until the sequence changes.
        let hadUnresolvedReplacement: Bool
        let hasUnprobedImprovingPivot: Bool
        let allConverged: Bool
        let improved: Bool
        let structurallyImproved: Bool
        let shouldAttemptStagedJoint: Bool
    }

    /// Work that may follow a cycle. Termination is not an action: it depends on state these actions change, since a relax round can improve the sequence, confirmation can clear stale floors, and a relation acceptance re-enters the loop.
    enum PostCycleAction: Equatable {
        case confirmConvergence
        case relationPass
        case improvingPivots
        case stagedJointPass
        case relaxRound
        case releaseDeferral
    }

    /// The actions to attempt, in order, with the loop control values that follow from the cycle.
    struct PostCycleEvaluation: Equatable {
        let actions: [PostCycleAction]
        let newStallBudget: Int
        let newDeferBindInner: Bool
    }

    /// Decides what follows a cycle from its outcome, the stall budget, and bind-inner deferral.
    static func evaluatePostCycle(
        outcome: CycleOutcome,
        stallBudget: Int,
        maxStalls: Int,
        deferBindInner: Bool
    ) -> PostCycleEvaluation {
        var actions: [PostCycleAction] = []

        if outcome.anyAccepted == false, outcome.allConverged {
            actions.append(.confirmConvergence)
            // Relation search runs after confirmation: value search writes convergence records mid-cycle, so on a run that stalls in its first cycle nothing would rebuild a source that could see them. This is where the stall signature, everything converged and nothing accepted, is both observable and actionable.
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

        var newDeferBindInner = deferBindInner
        if deferBindInner, outcome.structurallyImproved == false {
            newDeferBindInner = false
            actions.append(.releaseDeferral)
        }

        return PostCycleEvaluation(
            actions: actions,
            newStallBudget: newStallBudget,
            newDeferBindInner: newDeferBindInner
        )
    }

    /// Filters probing actions by encoder eligibility. Releasing deferral emits no probe, so it stays eligible in restricted runs.
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
            case .releaseDeferral:
                true
        }
    }
}
