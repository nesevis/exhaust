import Testing
@testable import ExhaustCore

@Suite("PostAcceptance")
struct PostAcceptanceTests {

    private static let defaultPriority = DispatchPriority(
        structuralBenefit: 1,
        valueBenefit: 0,
        reductionMagnitude: 0,
        estimatedCost: 1
    )

    // MARK: - Non-Accepted

    @Test("Rejected probe returns continueDispatching")
    func rejectedProbe() {
        let outcome = ChoiceGraphScheduler.ProbeLoopOutcome(
            accepted: false,
            requiresRebuild: false,
            treeIsStripped: false
        )
        let action = ChoiceGraphScheduler.evaluateAcceptance(
            outcome: outcome,
            operation: .remove(.subtree(nodeID: 0, yield: 1))
        )
        #expect(action == .continueDispatching)
    }

    // MARK: - Value-Only Acceptance

    @Test("Value-only acceptance without rebuild continues dispatching")
    func valueOnlyContinues() {
        let outcome = ChoiceGraphScheduler.ProbeLoopOutcome(
            accepted: true,
            requiresRebuild: false,
            treeIsStripped: false
        )
        let action = ChoiceGraphScheduler.evaluateAcceptance(
            outcome: outcome,
            operation: .minimize(.valueLeaves(ValueMinimizationScope(
                leaves: [LeafEntry(nodeID: 0)],
                batchZeroEligible: false
            )))
        )
        #expect(action == .continueDispatching)
    }

    // MARK: - Structural Acceptance

    @Test("Structural acceptance triggers rebuild")
    func structuralRebuilds() {
        let outcome = ChoiceGraphScheduler.ProbeLoopOutcome(
            accepted: true,
            requiresRebuild: true,
            treeIsStripped: false
        )
        let action = ChoiceGraphScheduler.evaluateAcceptance(
            outcome: outcome,
            operation: .remove(.subtree(nodeID: 0, yield: 1))
        )
        #expect(action == .rebuildAndResume(treeIsStripped: false))
    }

    @Test("Stripped tree propagates through rebuild action")
    func strippedPropagates() {
        let outcome = ChoiceGraphScheduler.ProbeLoopOutcome(
            accepted: true,
            requiresRebuild: true,
            treeIsStripped: true
        )
        let action = ChoiceGraphScheduler.evaluateAcceptance(
            outcome: outcome,
            operation: .replace(.branchPivot(pickNodeID: 0, targetBranchID: 1))
        )
        #expect(action == .rebuildAndResume(treeIsStripped: true))
    }

    // MARK: - Bound Value Acceptance

    @Test("Bound value acceptance always rebuilds regardless of requiresRebuild flag")
    func boundValueAlwaysRebuilds() {
        let scope = BoundValueScope(
            bindNodeID: 0,
            upstreamLeafNodeID: 1,
            downstreamNodeIDs: [2],
            boundSubtreeSize: 1
        )
        let outcome = ChoiceGraphScheduler.ProbeLoopOutcome(
            accepted: true,
            requiresRebuild: false,
            treeIsStripped: false
        )
        let action = ChoiceGraphScheduler.evaluateAcceptance(
            outcome: outcome,
            operation: .minimize(.boundValue(scope))
        )
        #expect(action == .rebuildAndResume(treeIsStripped: false))
    }

    @Test("Bound value acceptance with requiresRebuild also rebuilds")
    func boundValueWithRequiresRebuild() {
        let scope = BoundValueScope(
            bindNodeID: 0,
            upstreamLeafNodeID: 1,
            downstreamNodeIDs: [2],
            boundSubtreeSize: 1
        )
        let outcome = ChoiceGraphScheduler.ProbeLoopOutcome(
            accepted: true,
            requiresRebuild: true,
            treeIsStripped: true
        )
        let action = ChoiceGraphScheduler.evaluateAcceptance(
            outcome: outcome,
            operation: .minimize(.boundValue(scope))
        )
        #expect(action == .rebuildAndResume(treeIsStripped: true))
    }

    // MARK: - Exchange and Permutation

    @Test("Exchange acceptance without rebuild continues dispatching")
    func exchangeContinues() {
        let outcome = ChoiceGraphScheduler.ProbeLoopOutcome(
            accepted: true,
            requiresRebuild: false,
            treeIsStripped: false
        )
        let action = ChoiceGraphScheduler.evaluateAcceptance(
            outcome: outcome,
            operation: .exchange(.tandem(TandemScope(groups: [])))
        )
        #expect(action == .continueDispatching)
    }

    @Test("Permutation acceptance without rebuild continues dispatching")
    func permutationContinues() {
        let outcome = ChoiceGraphScheduler.ProbeLoopOutcome(
            accepted: true,
            requiresRebuild: false,
            treeIsStripped: false
        )
        let action = ChoiceGraphScheduler.evaluateAcceptance(
            outcome: outcome,
            operation: .permute(.siblingPermutation(parentNodeID: 0, swappableGroups: []))
        )
        #expect(action == .continueDispatching)
    }
}
