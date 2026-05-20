import Testing
@testable import ExhaustCore

@Suite("PostCycleEvaluation")
struct PostCycleDecisionTests {
    private static let maxStalls = 4

    private static func evaluate(
        anyAccepted: Bool = false,
        hadReplacementShortlexRejection: Bool = false,
        allConverged: Bool = false,
        improved: Bool = false,
        structurallyImproved: Bool = false,
        stallBudget: Int = 4,
        deferBindInner: Bool = false
    ) -> ChoiceGraphScheduler.PostCycleEvaluation {
        ChoiceGraphScheduler.evaluatePostCycle(
            outcome: .init(
                anyAccepted: anyAccepted,
                hadReplacementShortlexRejection: hadReplacementShortlexRejection,
                allConverged: allConverged,
                improved: improved,
                structurallyImproved: structurallyImproved
            ),
            stallBudget: stallBudget,
            maxStalls: maxStalls,
            deferBindInner: deferBindInner
        )
    }

    // MARK: - Convergence Confirmation

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

    // MARK: - Relax Round

    @Test("Relax round when stalled with replacement shortlex rejections")
    func relaxWhenStalledWithShortlexRejection() {
        let result = Self.evaluate(
            anyAccepted: false,
            hadReplacementShortlexRejection: true
        )
        #expect(result.actions.contains(.relaxRound))
    }

    @Test("No relax round when accepted")
    func noRelaxWhenAccepted() {
        let result = Self.evaluate(
            anyAccepted: true,
            hadReplacementShortlexRejection: true
        )
        #expect(result.actions.contains(.relaxRound) == false)
    }

    @Test("No relax round without replacement shortlex rejections")
    func noRelaxWithoutShortlexRejection() {
        let result = Self.evaluate(
            anyAccepted: false,
            hadReplacementShortlexRejection: false
        )
        #expect(result.actions.contains(.relaxRound) == false)
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

    @Test("Full convergence stall: confirmation only, no relax")
    func fullConvergenceStall() {
        let result = Self.evaluate(
            anyAccepted: false,
            allConverged: true,
            structurallyImproved: false
        )
        #expect(result.actions.contains(.confirmConvergence))
        #expect(result.actions.contains(.relaxRound) == false)
    }

    @Test("Stalled with shortlex rejection and convergence: confirmation and relax")
    func stalledWithShortlexAndConvergence() {
        let result = Self.evaluate(
            anyAccepted: false,
            hadReplacementShortlexRejection: true,
            allConverged: true,
            structurallyImproved: false
        )
        #expect(result.actions.contains(.confirmConvergence))
        #expect(result.actions.contains(.relaxRound))
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
}
