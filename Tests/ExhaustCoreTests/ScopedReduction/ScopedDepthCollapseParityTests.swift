import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Scoped depth collapse parity")
struct ScopedDepthCollapseParityTests {
    @Test(
        "Scoped depth collapse reproduces the encoder's trace, accounting, and result",
        arguments: [0, 1, 2, 3, 4, 5]
    )
    func parity(failingCount: Int) throws {
        let fixture = try DepthCollapseFixture(failingCount: failingCount)
        let legacy = fixture.runLegacy()
        let scoped = fixture.runScoped()

        #expect(scoped.events == legacy.events)
        #expect(scoped.report.counts == legacy.report.counts)
        #expect(scoped.report.anyAccepted == legacy.report.anyAccepted)
        #expect(scoped.report.anyRequiresRebuild == legacy.report.anyRequiresRebuild)
        #expect(scoped.report.latestTreeIsStripped == legacy.report.latestTreeIsStripped)
        #expect(scoped.report.acceptedLeafNodeIDs == legacy.report.acceptedLeafNodeIDs)
        #expect(scoped.report.searchReport.convergenceRecords == legacy.report.convergenceRecords)
        #expect(Array(scoped.result.incumbent.sequence) == Array(legacy.state.sequence))
        #expect(scoped.result.rejectCache == legacy.state.rejectCache)
    }

    @Test("The cases cover an accepted collapse and a search that rejects every probe")
    func casesCoverAcceptanceAndRejection() throws {
        let reports = try [0, 1, 2, 3, 4, 5].map { try DepthCollapseFixture(failingCount: $0).runLegacy().report }

        #expect(reports.contains { report in report.anyAccepted })
        #expect(reports.contains { report in report.anyAccepted == false && report.probeCount > 1 })
    }
}

// MARK: - Fixture

/// A recursive generator that appends one value per layer, generated deep enough that its root depth leaf can collapse. The property fails while the array holds at least `failingCount` elements.
struct DepthCollapseFixture {
    struct LegacyRun {
        let events: [ProbeTraceRecorder.Event]
        let report: PassReport
        let state: ProbeSessionFixtureState
    }

    struct ScopedRun {
        let events: [ProbeTraceRecorder.Event]
        let report: ScopedPassReport
        let result: ScopedReductionInterpreter.Result
    }

    let generator: AnyGenerator
    let tree: ChoiceTree
    let graph: ChoiceGraph
    let sequence: ChoiceSequence
    let depthScope: ValueMinimizationScope
    let scope: EncoderInput
    let property: (Any) -> Bool
    let output: [UInt64]
    let hasBind: Bool

    init(failingCount: Int) throws {
        let typed = Gen.recursive(baseValue: [UInt64](), depthRange: 0 ... 6) { recurse, _ in
            Gen.zip(recurse(), Gen.choose(in: UInt64(0) ... 9)).map { prefix, value in prefix + [value] }
        }
        var samples = ValueAndChoiceTreeInterpreter(typed, materializePicks: true, seed: 42, maxRuns: 200)
        var deepSample: (value: [UInt64], tree: ChoiceTree)?
        while deepSample == nil, let sample = try samples.next() {
            if sample.0.count >= 4 {
                deepSample = (value: sample.0, tree: sample.1)
            }
        }
        guard let generated = deepSample else {
            throw DepthCollapseFixtureError.noDeepSample
        }
        let built = ChoiceGraph.build(from: generated.tree)
        let scopes = DepthCollapseQuery.build(graph: built)
        guard case let .depthCollapse(valueScope) = scopes.first else {
            throw DepthCollapseFixtureError.noDepthScope
        }
        let flattened = ChoiceSequence(generated.tree)
        generator = typed.erase()
        tree = generated.tree
        graph = built
        sequence = flattened
        depthScope = valueScope
        scope = EncoderInput(
            transformation: GraphTransformation(
                operation: .minimize(.depthCollapse(valueScope)),
                priority: .zeroBenefit
            ),
            baseSequence: flattened,
            tree: generated.tree,
            graph: built,
            warmStartRecords: [:]
        )
        property = { output in (output as! [UInt64]).count < failingCount }
        output = generated.value
        hasBind = flattened.contains { entry in
            if case .bind = entry {
                return true
            }
            return false
        }
    }

    func runLegacy() -> LegacyRun {
        var state = ProbeSessionFixtureState(
            sequence: sequence,
            tree: tree,
            output: output,
            graph: graph,
            gen: generator,
            property: property
        )
        let recorder = ProbeTraceRecorder()
        var encoder = ChoiceGraphScheduler.selectEncoder(for: scope.transformation.operation, gen: generator)
        encoder.start(scope: scope)
        let session = ProbeSession(
            encoder: encoder,
            transformation: scope.transformation,
            boundValueFingerprint: nil,
            baseSequence: sequence,
            hasBind: hasBind,
            observer: { [weak recorder] in recorder?.record($0) }
        )
        let report = session.runToCompletion(state: &state)
        return LegacyRun(events: recorder.events, report: report, state: state)
    }

    func runScoped() -> ScopedRun {
        let recorder = ProbeTraceRecorder()
        let result = ScopedReductionInterpreter.run(
            ScopedDepthCollapseEncoder(tuning: ScopedReductionTuning()).reducer(depthScope, input: scope),
            context: ScopedReductionInterpreter.Context(
                incumbent: ScopedCounterexample(
                    sequence: sequence,
                    tree: tree,
                    output: ScopedOutputHandle(value: output)
                ),
                graph: graph,
                rejectCache: [],
                decoder: ScopedDecoder(
                    generator: generator,
                    property: property,
                    probeWrapper: nil,
                    hasBind: hasBind
                ),
                encoderName: .depthCollapse,
                observer: { [weak recorder] in recorder?.record($0) }
            )
        )
        return ScopedRun(events: recorder.events, report: result.report, result: result)
    }
}

private enum DepthCollapseFixtureError: Error {
    case noDeepSample
    case noDepthScope
}
