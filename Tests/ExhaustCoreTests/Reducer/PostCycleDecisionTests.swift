import Testing
@testable import ExhaustCore

@Suite("PostCycleEvaluation")
struct PostCycleDecisionTests {
    @Test("Convergence confirmation when stalled and all converged")
    func confirmConvergenceWhenStalledAndConverged() {
        let result = Self.evaluate(anyAccepted: false, allConverged: true)
        #expect(result.actions.contains(.confirmConvergence))
    }

    @Test("No convergence confirmation when any accepted")
    func noConfirmationWhenAccepted() {
        let result = Self.evaluate(anyAccepted: true, allConverged: true)
        #expect(result.actions.contains(.confirmConvergence) == false)
    }

    @Test("No convergence confirmation when not all converged")
    func noConfirmationWhenNotConverged() {
        let result = Self.evaluate(anyAccepted: false, allConverged: false)
        #expect(result.actions.contains(.confirmConvergence) == false)
    }

    // MARK: - Relation Pass

    @Test("Relation pass when stalled and all converged")
    func relationPassWhenStalledAndConverged() {
        let result = Self.evaluate(anyAccepted: false, allConverged: true)
        #expect(result.actions.contains(.relationPass))
    }

    @Test("Relation pass follows convergence confirmation")
    func relationPassFollowsConfirmation() {
        let result = Self.evaluate(anyAccepted: false, allConverged: true)
        let confirmIndex = result.actions.firstIndex(of: .confirmConvergence)
        let relationIndex = result.actions.firstIndex(of: .relationPass)
        #expect(confirmIndex != nil)
        #expect(relationIndex != nil)
        if let confirmIndex, let relationIndex {
            #expect(confirmIndex < relationIndex)
        }
    }

    @Test("No relation pass when any accepted")
    func noRelationPassWhenAccepted() {
        let result = Self.evaluate(anyAccepted: true, allConverged: true)
        #expect(result.actions.contains(.relationPass) == false)
    }

    @Test("No relation pass when not all converged")
    func noRelationPassWhenNotConverged() {
        let result = Self.evaluate(anyAccepted: false, allConverged: false)
        #expect(result.actions.contains(.relationPass) == false)
    }

    // MARK: - Excursion

    @Test("Excursion on the terminal stall with replacement shortlex rejections")
    func excursionOnTerminalStallWithShortlexRejection() {
        let result = Self.evaluate(
            anyAccepted: false,
            hadUnresolvedReplacement: true,
            stallBudget: 1
        )
        #expect(result.actions.contains(.excursion))
    }

    @Test("No excursion before the terminal stall")
    func noExcursionBeforeTerminalStall() {
        let result = Self.evaluate(
            anyAccepted: false,
            hadUnresolvedReplacement: true,
            allConverged: false,
            stallBudget: 4
        )
        #expect(result.actions.contains(.excursion) == false)
    }

    @Test("Improving pivots run on any stalled cycle")
    func improvingPivotsOnAnyStall() {
        let result = Self.evaluate(
            anyAccepted: false,
            hasUnprobedImprovingPivot: true,
            stallBudget: 4
        )
        #expect(result.actions.contains(.improvingPivots))
        #expect(result.actions.contains(.excursion) == false)
    }

    @Test("No excursion when accepted")
    func noExcursionWhenAccepted() {
        let result = Self.evaluate(
            anyAccepted: true,
            hadUnresolvedReplacement: true
        )
        #expect(result.actions.contains(.excursion) == false)
    }

    @Test("No excursion without replacement shortlex rejections")
    func noExcursionWithoutShortlexRejection() {
        let result = Self.evaluate(
            anyAccepted: false,
            hadUnresolvedReplacement: false
        )
        #expect(result.actions.contains(.excursion) == false)
    }

    // MARK: - Stall Budget

    @Test("Improvement resets stall budget to maxStalls")
    func improvementResetsStallBudget() {
        let result = Self.evaluate(improved: true, stallBudget: 1)
        #expect(result.newStallBudget == Self.maxStalls)
    }

    @Test("No improvement decrements stall budget")
    func noImprovementDecrementsStallBudget() {
        let result = Self.evaluate(improved: false, stallBudget: 3)
        #expect(result.newStallBudget == 2)
    }

    // MARK: - Deferral Release

    @Test("Deferral released when no structural improvement")
    func deferralReleasedWhenNoStructuralImprovement() {
        let result = Self.evaluate(
            structurallyImproved: false,
            deferBindInner: true
        )
        #expect(result.newDeferBindInner == false)
        #expect(result.actions.contains(.releaseDeferral))
    }

    @Test("Deferral persists when structurally improved")
    func deferralPersistsWhenStructurallyImproved() {
        let result = Self.evaluate(
            structurallyImproved: true,
            deferBindInner: true
        )
        #expect(result.newDeferBindInner)
        #expect(result.actions.contains(.releaseDeferral) == false)
    }

    @Test("No deferral action when deferral already false")
    func noDeferralActionWhenAlreadyFalse() {
        let result = Self.evaluate(
            structurallyImproved: false,
            deferBindInner: false
        )
        #expect(result.actions.contains(.releaseDeferral) == false)
    }

    // MARK: - Combined Scenarios

    @Test("Full convergence stall: confirmation only, no excursion")
    func fullConvergenceStall() {
        let result = Self.evaluate(
            anyAccepted: false,
            allConverged: true,
            structurallyImproved: false
        )
        #expect(result.actions.contains(.confirmConvergence))
        #expect(result.actions.contains(.excursion) == false)
    }

    @Test("Stalled with shortlex rejection and convergence: confirmation and excursion")
    func stalledWithShortlexAndConvergence() {
        let result = Self.evaluate(
            anyAccepted: false,
            hadUnresolvedReplacement: true,
            allConverged: true,
            structurallyImproved: false
        )
        #expect(result.actions.contains(.confirmConvergence))
        #expect(result.actions.contains(.excursion))
    }

    @Test("Productive cycle: no special actions")
    func productiveCycle() {
        let result = Self.evaluate(
            anyAccepted: true,
            improved: true,
            structurallyImproved: true
        )
        #expect(result.actions.isEmpty)
        #expect(result.newStallBudget == Self.maxStalls)
    }

    @Test("Evaluation does not contain termination — termination is post-effect")
    func noTerminationAction() {
        let result = Self.evaluate(
            anyAccepted: false,
            allConverged: true,
            structurallyImproved: false
        )
        let actionDescriptions = result.actions.map { "\($0)" }
        for description in actionDescriptions {
            #expect(description.contains("terminate") == false)
        }
    }

    @Test("Numeric fallback precedes the excursion and never triggers it")
    func numericFallbackOrdering() {
        let evaluation = ChoiceGraphScheduler.evaluatePostCycle(
            outcome: .init(
                anyAccepted: false,
                hadUnresolvedReplacement: true,
                hasUnprobedImprovingPivot: false,
                allConverged: true,
                improved: false,
                structurallyImproved: false,
                shouldAttemptNumericPairs: true
            ),
            stallBudget: 4,
            maxStalls: 4,
            deferBindInner: false
        )
        #expect(evaluation.actions == [.confirmConvergence, .relationPass, .pairwiseNumericPass, .excursion])
        let numericOnly = ChoiceGraphScheduler.evaluatePostCycle(
            outcome: .init(
                anyAccepted: false,
                hadUnresolvedReplacement: false,
                hasUnprobedImprovingPivot: false,
                allConverged: false,
                improved: false,
                structurallyImproved: false,
                shouldAttemptNumericPairs: true
            ),
            stallBudget: 4,
            maxStalls: 4,
            deferBindInner: false
        )
        #expect(numericOnly.actions == [.pairwiseNumericPass])
    }

    @Test("Numeric encoders have separate post-cycle actions before the excursion", arguments: [false, true], [false, true])
    func independentNumericFallbackActions(pairwise: Bool, staged: Bool) {
        let evaluation = ChoiceGraphScheduler.evaluatePostCycle(
            outcome: .init(
                anyAccepted: false,
                hadUnresolvedReplacement: true,
                hasUnprobedImprovingPivot: false,
                allConverged: false,
                improved: false,
                structurallyImproved: false,
                shouldAttemptNumericPairs: pairwise,
                shouldAttemptStagedJoint: staged
            ),
            stallBudget: 1,
            maxStalls: 4,
            deferBindInner: false
        )
        var expected: [ChoiceGraphScheduler.PostCycleAction] = []
        if pairwise { expected.append(.pairwiseNumericPass) }
        if staged { expected.append(.stagedJointPass) }
        expected.append(.excursion)
        #expect(evaluation.actions == expected)
    }

    // MARK: - Helpers

    private static let maxStalls = 4

    private static func evaluate(
        anyAccepted: Bool = false,
        hadUnresolvedReplacement: Bool = false,
        hasUnprobedImprovingPivot: Bool = false,
        allConverged: Bool = false,
        improved: Bool = false,
        structurallyImproved: Bool = false,
        stallBudget: Int = 4,
        deferBindInner: Bool = false
    ) -> ChoiceGraphScheduler.PostCycleEvaluation {
        ChoiceGraphScheduler.evaluatePostCycle(
            outcome: .init(
                anyAccepted: anyAccepted,
                hadUnresolvedReplacement: hadUnresolvedReplacement,
                hasUnprobedImprovingPivot: hasUnprobedImprovingPivot,
                allConverged: allConverged,
                improved: improved,
                structurallyImproved: structurallyImproved,
                shouldAttemptNumericPairs: false
            ),
            stallBudget: stallBudget,
            maxStalls: maxStalls,
            deferBindInner: deferBindInner
        )
    }
}
