import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Reducer probe admission accounting")
struct ProbeAcceptanceAccountingTests {
    @Test("Exact sessions count admission after the shortlex gate, including lateral moves", arguments: [UInt64(0), 1, 2])
    func exactSessionAdmission(candidate: UInt64) throws {
        var propertyCalls = 0
        var fixture = try SingleProbeFixture(candidate: candidate) { _ in
            propertyCalls += 1
            return false
        }
        let baseline = fixture.state.sequence
        let report = try fixture.session.runToCompletion(state: &fixture.state)
        let admitted = candidate <= 1
        #expect(propertyCalls == 1)
        #expect(report.probeCount == 1)
        #expect(report.counts.propertyFailed == 1)
        #expect(report.counts.propertyPassed == 0)
        #expect(report.counts.materializationAttempts == 2)
        #expect(report.counts.terminalOutcomes == 1)
        #expect(report.anyAccepted == admitted)
        #expect(report.acceptCount == (admitted ? 1 : 0))
        #expect(report.decoderRejectCount == (admitted ? 0 : 1))
        #expect(fixture.state.output as? UInt64 == (admitted ? candidate : 1))
        #expect(fixture.state.sequence.shortLexPrecedes(baseline) == (candidate == 0))
        #expect(fixture.recorder.events.contains(.terminated(1, .accepted, materializationAttempts: 2)) == admitted)
        #expect(fixture.recorder.events.contains(.terminated(1, .propertyFailedNotAdmitted(.enlargingCommit), materializationAttempts: 2)) == (admitted == false))
        let repeated = fixture.session.report()
        #expect(repeated.acceptCount == report.acceptCount)
        #expect(repeated.decoderRejectCount == report.decoderRejectCount)
    }

    @Test("Materialization rejection and property success never count as admission", arguments: [false, true])
    func rejectedOutcomesAreNotAccepted(propertyPasses: Bool) throws {
        var calls = 0
        var fixture = try SingleProbeFixture(candidate: propertyPasses ? 0 : 5) { _ in
            calls += 1
            #expect(propertyPasses)
            return true
        }
        let report = try fixture.session.runToCompletion(state: &fixture.state)
        #expect(calls == (propertyPasses ? 1 : 0))
        #expect(report.probeCount == 1)
        #expect(report.counts.propertyPassed == (propertyPasses ? 1 : 0))
        #expect(report.counts.rejectedDuringMaterialization == (propertyPasses ? 0 : 1))
        #expect(report.counts.propertyFailed == 0)
        #expect(report.counts.materializationAttempts == 1)
        #expect(report.anyAccepted == false)
        #expect(report.acceptCount == 0)
        #expect(report.decoderRejectCount == 1)
        #expect(fixture.state.output as? UInt64 == 1)
    }

    @Test("Aggregated run and encoder totals retain rejected failures separately from admissions")
    func aggregationPreservesAdmissionCounts() throws {
        var stats = ReductionStats()
        var other = ReductionStats()
        for candidate: UInt64 in [0, 1, 2] {
            var fixture = try SingleProbeFixture(candidate: candidate) { _ in false }
            let report = try fixture.session.runToCompletion(state: &fixture.state)
            stats.record(report.counts, for: .composed)
        }
        var passing = try SingleProbeFixture(candidate: 0) { _ in true }
        let report = try passing.session.runToCompletion(state: &passing.state)
        other.record(report.counts, for: .composed)
        stats.merge(other)
        #expect(stats.reductionProbes == 4)
        #expect(stats.reductionProbesWherePropertyFailed == 3)
        #expect(stats.reductionProbesWherePropertyPassed == 1)
        #expect(stats.reductionProbesAccepted == 2)
        #expect(stats.encoderProbesAccepted[.composed] == 2)
        #expect(stats.encoderProbesRejectedByDecoder[.composed] == 2)
        #expect(stats.materializationsBySite[.decoder] == 7)
    }

    @Test("Final numeric reordering still counts an admitted shortlex regression")
    func reorderAcceptanceIsCounted() throws {
        let generator = Gen.arrayOf(Gen.choose(in: Int64(-10) ... 10), within: 3 ... 3)
        let tree = try #require(try Interpreters.reflect(generator, with: [Int64(0), -1, 1]))
        let sequence = ChoiceSequence(tree)
        let graph = ChoiceGraph.build(from: tree)
        let reordering = try #require(ReorderingQuery.build(graph: graph))
        let scope = EncoderInput(
            transformation: GraphTransformation(operation: .reorder(reordering), priority: .zeroBenefit),
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        )
        var state = ProbeSessionFixtureState(sequence: sequence, tree: tree, output: [Int64(0), -1, 1], graph: graph, gen: generator.erase(), property: { _ in false })
        var session = state.makeSession(for: scope)
        let report = try session.runToCompletion(state: &state)
        #expect(sequence.shortLexPrecedes(state.sequence))
        #expect(state.output as? [Int64] == [-1, 0, 1])
        #expect(report.anyAccepted)
        #expect(report.acceptCount == 1)
        #expect(report.counts.propertyFailed == 1)
        #expect(report.decoderRejectCount == 0)
    }

    @Test("Convergence confirmation counts a successful floor invalidation without committing its probe", arguments: [false, true])
    func confirmationAdmission(propertyPasses: Bool) throws {
        let generator = Gen.choose(in: UInt64(0) ... 3)
        var machine = try reflectedMachine(generator: generator, value: UInt64(1), enabledEncoders: [.convergenceConfirmation]) { _ in propertyPasses }
        let baseline = machine.sequence
        let nodeID = try #require(machine.graph.leafNodes.first)
        machine.graph.convergenceStore[nodeID] = ConvergedOrigin(bound: 1, signal: .monotoneConvergence, configuration: .binarySearchSemanticSimplest, cycle: 0)
        let stale = try machine.confirmConvergence()
        #expect(stale == (propertyPasses == false))
        #expect((machine.graph.convergenceStore[nodeID] == nil) == (propertyPasses == false))
        #expect(machine.sequence == baseline)
        #expect(machine.output as? UInt64 == 1)
        #expect(machine.stats.encoderProbes[.convergenceConfirmation] == 1)
        #expect(machine.stats.encoderProbesAccepted[.convergenceConfirmation] == (propertyPasses ? 0 : 1))
        #expect(machine.stats.encoderProbesWherePropertyFailed[.convergenceConfirmation] == (propertyPasses ? 0 : 1))
        #expect(machine.stats.encoderProbesRejectedByDecoder[.convergenceConfirmation] == (propertyPasses ? 1 : 0))
    }

    @Test("An admitted excursion perturbation retains its spent-work count after rollback")
    func provisionalAdmissionSurvivesRollback() throws {
        let generator = Gen.arrayOf(twoArms, within: 2 ... 2)
        var tuning = SchedulerTuning()
        tuning.relaxMaterializationBudget = 1
        var propertyCalls = 0
        var machine = try reflectedMachine(generator: generator, value: [UInt64(10), 80], enabledEncoders: [.substitution], tuning: tuning) { _ in
            propertyCalls += 1
            return false
        }
        let baseline = machine.sequence
        var candidates = RelaxCandidateCursor(sequence: baseline, graph: machine.graph, limit: 1, isEncoderEnabled: machine.isEncoderEnabled)
        let first = candidates.next()
        let perturbation = try #require(first)
        #expect(perturbation.shortLexPrecedes(baseline) == false)
        let committed = try machine.runExcursion()
        #expect(committed == false)
        #expect(machine.sequence == baseline)
        #expect(machine.output as? [UInt64] == [10, 80])
        #expect(propertyCalls == 1)
        #expect(machine.stats.reductionProbes == 1)
        #expect(machine.stats.reductionProbesWherePropertyFailed == 1)
        #expect(machine.stats.reductionProbesAccepted == 1)
        #expect(machine.stats.materializationsBySite[.decoder] == 2)
    }

    @Test("Improving pivots count only the failing fill they admit")
    func improvingPivotAdmission() throws {
        var machine = try reflectedMachine(generator: twoArms, value: UInt64(250), enabledEncoders: [.branchPivot]) { $0 < 80 }
        let admitted = try machine.runImprovingPivotPass()
        #expect(admitted)
        #expect(machine.output as? UInt64 == 100)
        #expect(machine.stats.relaxImprovingProbes == 2)
        #expect(machine.stats.relaxImprovingAcceptances == 1)
        #expect(machine.stats.reductionProbes == 2)
        #expect(machine.stats.reductionProbesWherePropertyPassed == 1)
        #expect(machine.stats.reductionProbesWherePropertyFailed == 1)
        #expect(machine.stats.reductionProbesAccepted == 1)
        #expect(machine.stats.materializationsBySite[.decoder] == 3)
    }
}

// MARK: - Test Helpers

/// Uses the real one-shot lifted stage to isolate session admission from an encoder's own candidate ordering.
private struct SingleProbeFixture {
    var state: ProbeSessionFixtureState
    var session: ProbeSession
    let recorder: ProbeTraceRecorder

    init(candidate: UInt64, property: @escaping (Any) -> Bool) throws {
        let generator = Gen.choose(in: UInt64(0) ... 3)
        let tree = try #require(try Interpreters.reflect(generator, with: UInt64(1)))
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let proposalTree = ChoiceTree.uint64(candidate, in: 0 ... 3)
        let operation = GraphOperation.minimize(.valueLeaves(ValueMinimizationScope(leaves: [LeafEntry(nodeID: 0)], batchZeroEligible: false)))
        let transformation = GraphTransformation(operation: operation, priority: .zeroBenefit)
        let scope = EncoderInput(
            transformation: transformation,
            baseSequence: ChoiceSequence(proposalTree),
            tree: proposalTree,
            graph: ChoiceGraph.build(from: proposalTree),
            warmStartRecords: [:]
        )
        var encoder = EncoderDispatch.liftedStage(GraphLiftedStageEncoder(
            name: .composed,
            mutation: .leafValues([LeafChange(leafNodeID: 0, newValue: ChoiceValue(candidate, tag: .uint64), mayReshape: false)])
        ))
        encoder.start(scope: scope)
        recorder = ProbeTraceRecorder()
        let recorder = recorder
        session = ProbeSession(
            encoder: encoder,
            transformation: transformation,
            boundValueFingerprint: nil,
            baseSequence: sequence,
            hasBind: false,
            observer: { [weak recorder] in recorder?.record($0) }
        )
        state = ProbeSessionFixtureState(sequence: sequence, tree: tree, output: UInt64(1), graph: graph, gen: generator.erase(), property: property)
    }
}

private let twoArms = Gen.pick(choices: [
    (1, Gen.choose(in: UInt64(0) ... 100)),
    (1, Gen.choose(in: UInt64(200) ... 300)),
])

/// Shares the generator and reconstructed tree with the production decoder so admission tests cannot succeed through fixture mismatch.
private func reflectedMachine<Output>(
    generator: Generator<Output>,
    value: Output,
    enabledEncoders: Set<EncoderName>,
    tuning: SchedulerTuning = .init(),
    property: @escaping (Output) -> Bool
) throws -> ReductionMachine {
    let tree = try #require(try Interpreters.reflect(generator, with: value))
    return ReductionMachine(
        gen: generator,
        initialTree: tree,
        initialOutput: value,
        config: .init(maxStalls: 2, enabledEncoders: enabledEncoders, tuning: tuning),
        collectStats: true,
        property: property
    )
}
