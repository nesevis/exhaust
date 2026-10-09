import Testing
@testable import ExhaustCore

@Suite("Reduction pass policy")
struct ReductionPassPolicyTests {
    @Test("Pass policy retains caller routing state and required cache effects", arguments: [false, true])
    func preservesCallerState(acceptsProbes: Bool) throws {
        let generator = Gen.arrayOf(Gen.choose(in: 0 ... 100), within: 0 ... 5)
        let initial = [10, 20, 30]
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: initial,
            config: .init(maxStalls: 1, enabledEncoders: [.deletion]),
            collectStats: true,
            property: { _ in acceptsProbes == false }
        )
        let removal = try #require(RemovalQuery.elementRemovalScopes(graph: machine.graph).first)
        let transformation = GraphTransformation(
            operation: .remove(.elements(removal)),
            priority: .init(structuralBenefit: 0, valueBenefit: 0, reductionMagnitude: 0, estimatedCost: 1)
        )
        var encoder = ChoiceGraphScheduler.selectEncoder(for: transformation.operation, gen: machine.gen)
        encoder.start(scope: EncoderInput(
            transformation: transformation,
            baseSequence: machine.sequence,
            tree: machine.tree,
            graph: machine.graph,
            warmStartRecords: [:]
        ))
        var session = ProbeSession(
            encoder: encoder,
            transformation: transformation,
            boundValueFingerprint: nil,
            baseSequence: machine.sequence,
            hasBind: false
        )
        let report = session.runToCompletion(state: &machine)
        #expect(report.anyAccepted == acceptsProbes)
        #expect(report.anyRequiresRebuild == acceptsProbes)

        machine.dispatchPhase = .probing
        machine.pendingReport = report
        let fingerprint: UInt64 = 1234
        machine.convergence.gate.markFruitless(fingerprint)
        let action = machine.applyPassPolicy(report)

        #expect(machine.dispatchPhase == .probing)
        #expect(machine.pendingReport?.encoderName == report.encoderName)
        #expect(machine.pendingReport?.anyAccepted == report.anyAccepted)
        #expect(machine.pendingReport?.anyRequiresRebuild == report.anyRequiresRebuild)
        #expect(machine.passCounter == 1)
        #expect(machine.stats.encoderCounts[.deletion]?.emitted == report.counts.emitted)
        #expect(machine.anyAccepted == acceptsProbes)
        #expect(machine.anyAcceptanceEverOccurred == acceptsProbes)
        #expect(machine.convergence.gate.isFruitless(fingerprint) == (acceptsProbes == false))
        #expect(machine.scopeRejectionCache.isRejected(
            operation: transformation.operation,
            sequence: machine.sequence,
            graph: machine.graph
        ) == (acceptsProbes == false))
        let expectedAction: ChoiceGraphScheduler.PostAcceptanceAction = acceptsProbes
            ? .rebuildAndResume(treeIsStripped: report.latestTreeIsStripped)
            : .continueDispatching
        #expect(action == expectedAction)
    }
}
