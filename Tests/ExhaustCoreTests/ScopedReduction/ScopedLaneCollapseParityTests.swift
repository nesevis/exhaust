import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Scoped lane collapse parity")
struct ScopedLaneCollapseParityTests {
    @Test(
        "Scoped lane collapse reproduces the encoder's trace, accounting, and result",
        arguments: LaneCase.all
    )
    func parity(laneCase: LaneCase) throws {
        let fixture = try LaneCollapseFixture(laneCase)
        let legacy = fixture.runLegacy()
        let scoped = fixture.runScoped()

        #expect(scoped.events == legacy.events)
        #expect(scoped.report.counts == legacy.report.counts)
        #expect(scoped.report.anyAccepted == legacy.report.anyAccepted)
        #expect(scoped.report.anyRequiresRebuild == legacy.report.anyRequiresRebuild)
        #expect(scoped.report.latestTreeIsStripped == legacy.report.latestTreeIsStripped)
        #expect(scoped.report.acceptedLeafNodeIDs == legacy.report.acceptedLeafNodeIDs)
        #expect(Array(scoped.result.incumbent.sequence) == Array(legacy.state.sequence))
        #expect(scoped.result.rejectCache == legacy.state.rejectCache)
    }

    @Test("The cases cover an accepted collapse and a search that rejects every probe")
    func casesCoverAcceptanceAndRejection() throws {
        let reports = try LaneCase.all.map { try LaneCollapseFixture($0).runLegacy().report }

        #expect(reports.contains { report in report.anyAccepted })
        #expect(reports.contains { report in report.anyAccepted == false && report.probeCount > 1 })
    }
}

// MARK: - Cases

/// Lane-tagged commands and the number of concurrent commands the property needs to keep failing.
struct LaneCase: CustomStringConvertible, Sendable {
    let commands: [(UInt8, UInt64)]
    let concurrentNeeded: Int

    var description: String {
        "\(commands.map(\.0)) needs \(concurrentNeeded)"
    }

    static let all: [LaneCase] = [
        LaneCase(commands: [(1, 10), (0, 20), (2, 30), (0, 40), (1, 50)], concurrentNeeded: 2),
        LaneCase(commands: [(2, 10), (1, 20), (2, 30), (1, 40)], concurrentNeeded: 4),
        LaneCase(commands: [(1, 10), (2, 20), (1, 30)], concurrentNeeded: 0),
        LaneCase(commands: [(0, 10), (2, 20), (0, 30), (1, 40)], concurrentNeeded: 1),
    ]
}

// MARK: - Fixture

/// A reflected lane-tagged command array whose property fails while at least `concurrentNeeded` commands sit on concurrent lanes.
struct LaneCollapseFixture {
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
    let laneScope: ValueMinimizationScope
    let scope: EncoderInput
    let property: (Any) -> Bool
    let output: [(UInt8, UInt64)]

    init(_ laneCase: LaneCase) throws {
        let typed = LaneCollapseGenerators.laneTaggedArray(concurrencyLevel: 2)
        let reflected = try #require(try Interpreters.reflect(typed, with: laneCase.commands))
        let built = ChoiceGraph.build(from: reflected)
        guard case let .laneCollapse(valueScope) = LaneCollapseQuery.build(graph: built) else {
            throw LaneCollapseFixtureError.noLaneScope
        }
        let flattened = ChoiceSequence(reflected)
        generator = typed.erase()
        tree = reflected
        graph = built
        sequence = flattened
        laneScope = valueScope
        scope = EncoderInput(
            transformation: GraphTransformation(
                operation: .minimize(.laneCollapse(valueScope)),
                priority: .zeroBenefit
            ),
            baseSequence: flattened,
            tree: reflected,
            graph: built,
            warmStartRecords: [:]
        )
        let concurrentNeeded = laneCase.concurrentNeeded
        property = { output in (output as! [(UInt8, UInt64)]).count { $0.0 != 0 } < concurrentNeeded }
        output = laneCase.commands
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
            hasBind: false,
            observer: { [weak recorder] in recorder?.record($0) }
        )
        let report = session.runToCompletion(state: &state)
        return LegacyRun(events: recorder.events, report: report, state: state)
    }

    func runScoped() -> ScopedRun {
        let recorder = ProbeTraceRecorder()
        let result = ScopedReductionInterpreter.run(
            ScopedLaneCollapseEncoder(tuning: ScopedReductionTuning()).reducer(laneScope, input: scope),
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
                    hasBind: false
                ),
                encoderName: .laneCollapse,
                observer: { [weak recorder] in recorder?.record($0) }
            )
        )
        return ScopedRun(events: recorder.events, report: result.report, result: result)
    }
}

private enum LaneCollapseFixtureError: Error {
    case noLaneScope
}
