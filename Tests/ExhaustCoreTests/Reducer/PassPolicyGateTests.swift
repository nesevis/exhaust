import Testing
@testable import ExhaustCore

@Suite("Pass policy bind budgets")
struct PassPolicyGateTests {
    @Test("Ordinary acceptances clear fruitless verdicts without restoring unrelated bind budgets", arguments: [false, true], [false, true])
    func preservesBudgetDecay(accepted: Bool, requiresRebuild: Bool) throws {
        let generator = Gen.choose(in: UInt64(0) ... 10)
        let initial: UInt64 = 5
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        let scope = ValueMinimizationScope(leaves: [], batchZeroEligible: false)
        var gate = BoundValueGate(baseBudget: 16)
        let fingerprints: [UInt64] = [0xAAAA, 0xBBBB]
        for fingerprint in fingerprints {
            gate.recordOutcome(fingerprint: fingerprint, accepted: false)
            gate.recordOutcome(fingerprint: fingerprint, accepted: false)
        }
        gate.markDispatched(fingerprints[0])

        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: initial,
            config: .init(maxStalls: 2),
            collectStats: false,
            property: { _ in false }
        )
        machine.convergence.gate = gate
        let action = machine.applyPassPolicy(PassReport(
            encoderName: .valueSearch,
            transformation: .init(operation: .minimize(.valueLeaves(scope)), priority: .zeroBenefit),
            boundValueFingerprint: nil,
            composedUpstreamLifts: nil,
            liftMaterializations: nil,
            counts: .init(),
            anyAccepted: accepted,
            anyRequiresRebuild: accepted && requiresRebuild,
            latestTreeIsStripped: false,
            convergenceRecords: [:],
            hadUnresolvedReplacement: false,
            acceptedLeafNodeIDs: []
        ))
        #expect(action == (accepted && requiresRebuild ? .rebuildAndResume(treeIsStripped: false) : .continueDispatching))

        var runner = ScopedReductionRunner(
            generator: generator,
            initialTree: tree,
            initialOutput: initial,
            configuration: .init(maxStalls: 2),
            collectStats: false,
            property: { _ in false }
        )
        runner.gate = gate
        var report = ScopedPassReport()
        report.anyAccepted = accepted
        report.anyRequiresRebuild = accepted && requiresRebuild
        let scopedAction = runner.applyPassPolicy(.init(
            encoderScope: .valueSearch(scope),
            boundValueFingerprint: nil,
            report: report
        ))
        #expect(scopedAction == (accepted && requiresRebuild ? .rebuildAndResume : .continueDispatching))

        for resultingGate in [machine.convergence.gate, runner.gate] {
            for fingerprint in fingerprints {
                #expect(resultingGate.decayedBudget(fingerprint: fingerprint) == 4)
                #expect(resultingGate.isFruitless(fingerprint) == (accepted == false))
                #expect(resultingGate.isFirstDispatch(fingerprint: fingerprint) == false)
            }
            #expect(resultingGate.shouldDispatch(fingerprint: fingerprints[0]) == .skip)
            #expect(resultingGate.shouldDispatch(fingerprint: fingerprints[1]) == (accepted ? .classifyFirst : .skip))
            #expect(resultingGate.isFirstDispatch(fingerprint: 0xCCCC))
        }
    }
}
