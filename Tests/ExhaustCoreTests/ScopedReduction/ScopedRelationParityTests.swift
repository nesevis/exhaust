import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Scoped relation parity")
struct ScopedRelationParityTests {
    @Test(
        "Scoped relation reproduces the encoder's trace, accounting, and result",
        arguments: RelationCase.all
    )
    func parity(relationCase: RelationCase) throws {
        let fixture = try RelationFixture(relationCase)
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

    @Test("The cases cover a direct shot, a binary search along the line, signed leaves, and a search that rejects every probe")
    func casesCoverSearchPaths() throws {
        let runs = try RelationCase.all.map { relationCase in
            try (relationCase, RelationFixture(relationCase).runLegacy())
        }

        #expect(runs.contains { relationCase, run in relationCase.kind == .unsigned && run.report.anyAccepted })
        #expect(runs.contains { relationCase, run in relationCase.kind == .signed && run.report.anyAccepted })
        #expect(runs.contains { _, run in run.report.anyAccepted == false && run.report.probeCount > 1 })
    }
}

// MARK: - Cases

/// A generator family, a value reflected through it, and a property over the reflected output.
struct RelationCase: CustomStringConvertible, Sendable {
    enum Kind: Sendable {
        case unsigned
        case signed
    }

    let label: String
    let kind: Kind
    let value: [Double]
    let fails: @Sendable ([Double]) -> Bool

    var description: String {
        label
    }

    static let all: [RelationCase] = [
        RelationCase(label: "unsigned, any multiple of two to one", kind: .unsigned, value: [200, 100, 7], fails: { $0[0] == 2 * $0[1] && $0[1] >= 1 }),
        RelationCase(label: "unsigned, multiple of two to one at least ten", kind: .unsigned, value: [200, 100, 7], fails: { $0[0] == 2 * $0[1] && $0[1] >= 10 }),
        RelationCase(label: "unsigned, never fails", kind: .unsigned, value: [200, 100, 7], fails: { _ in false }),
        RelationCase(label: "signed, three to one at least six", kind: .signed, value: [90, 30], fails: { $0[0] == 3 * $0[1] && $0[1] >= 6 }),
    ]
}

// MARK: - Fixture

/// Reflects a case's value through its generator family, marks every leaf converged at its current value so the stall gate opens, and dispatches the relation scope ``RelationQuery`` builds.
struct RelationFixture {
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
    let relationScope: RelationScope
    let scope: EncoderInput
    let property: (Any) -> Bool
    let output: Any

    init(_ relationCase: RelationCase) throws {
        let fails = relationCase.fails
        let reflected: ChoiceTree
        switch relationCase.kind {
            case .unsigned:
                let typed = Gen.zip(
                    Gen.choose(in: UInt64(0) ... 1000),
                    Gen.choose(in: UInt64(0) ... 1000),
                    Gen.choose(in: UInt64(0) ... 1000)
                )
                let value = (UInt64(relationCase.value[0]), UInt64(relationCase.value[1]), UInt64(relationCase.value[2]))
                reflected = try #require(try Interpreters.reflect(typed, with: value))
                generator = typed.erase()
                output = value
                property = { output in
                    let (first, second, third) = output as! (UInt64, UInt64, UInt64)
                    return fails([Double(first), Double(second), Double(third)]) == false
                }
            case .signed:
                let typed = Gen.zip(Gen.choose(in: Int64(-100) ... 100), Gen.choose(in: Int64(-100) ... 100))
                let value = (Int64(relationCase.value[0]), Int64(relationCase.value[1]))
                reflected = try #require(try Interpreters.reflect(typed, with: value))
                generator = typed.erase()
                output = value
                property = { output in
                    let (first, second) = output as! (Int64, Int64)
                    return fails([Double(first), Double(second)]) == false
                }
        }
        let built = ChoiceGraph.stalled(from: reflected)
        let found = RelationQuery.build(graph: built).map { [$0] } ?? []
        let flattened = ChoiceSequence(reflected)
        tree = reflected
        graph = built
        sequence = flattened
        relationScope = try #require(found.first)
        scope = EncoderInput(
            transformation: GraphTransformation(operation: .exchange(.relation(relationScope)), priority: .zeroBenefit),
            baseSequence: flattened,
            tree: reflected,
            graph: built,
            warmStartRecords: [:]
        )
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
            ScopedRelationEncoder(tuning: ScopedReductionTuning()).reducer(relationScope, input: scope),
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
                encoderName: .relationSearch,
                observer: { [weak recorder] in recorder?.record($0) }
            )
        )
        return ScopedRun(events: recorder.events, report: result.report, result: result)
    }
}
