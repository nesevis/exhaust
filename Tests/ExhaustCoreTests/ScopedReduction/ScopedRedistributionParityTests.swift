import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Scoped redistribution parity")
struct ScopedRedistributionParityTests {
    @Test(
        "Scoped redistribution reproduces the encoder's trace, accounting, and result",
        arguments: RedistributionCase.all
    )
    func parity(redistributionCase: RedistributionCase) throws {
        let fixture = try RedistributionFixture(redistributionCase)
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

    @Test("The cases cover accepted transfers, mixed integer and float pairs, and a search that rejects every probe")
    func casesCoverSearchPaths() throws {
        let runs = try RedistributionCase.all.map { redistributionCase in
            try (redistributionCase, RedistributionFixture(redistributionCase).runLegacy())
        }

        #expect(runs.contains { redistributionCase, run in redistributionCase.kind == .unsigned && run.report.anyAccepted })
        #expect(runs.contains { redistributionCase, run in redistributionCase.kind == .signed && run.report.anyAccepted })
        #expect(runs.contains { redistributionCase, run in redistributionCase.kind == .mixed && run.report.anyAccepted })
        #expect(runs.contains { _, run in run.report.anyAccepted == false && run.report.probeCount > 1 })
    }
}

// MARK: - Cases

/// A generator family, a value reflected through it, and a property over the reflected output.
struct RedistributionCase: CustomStringConvertible, Sendable {
    enum Kind: Sendable {
        case unsigned
        case signed
        case mixed
    }

    let label: String
    let kind: Kind
    let value: [Double]
    let fails: @Sendable ([Double]) -> Bool

    var description: String {
        label
    }

    static let all: [RedistributionCase] = [
        RedistributionCase(label: "unsigned, sum at least 300", kind: .unsigned, value: [300, 50, 20], fails: { $0.reduce(0, +) >= 300 }),
        RedistributionCase(label: "unsigned, first carries the sum", kind: .unsigned, value: [300, 50, 20], fails: { $0[0] >= 100 && $0.reduce(0, +) >= 300 }),
        RedistributionCase(label: "unsigned, never fails", kind: .unsigned, value: [300, 50, 20], fails: { _ in false }),
        RedistributionCase(label: "signed, sum at least 50", kind: .signed, value: [60, -5], fails: { $0.reduce(0, +) >= 50 }),
        RedistributionCase(label: "mixed, sum at least 300", kind: .mixed, value: [40, 300.5], fails: { $0.reduce(0, +) >= 300 }),
    ]
}

// MARK: - Fixture

/// Reflects a case's value through its generator family and dispatches the first redistribution scope ``ExchangeQuery`` builds for it.
struct RedistributionFixture {
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
    let redistributionScope: RedistributionScope
    let scope: EncoderInput
    let property: (Any) -> Bool
    let output: Any

    init(_ redistributionCase: RedistributionCase) throws {
        let fails = redistributionCase.fails
        let reflected: ChoiceTree
        switch redistributionCase.kind {
            case .unsigned:
                let typed = Gen.zip(
                    Gen.choose(in: UInt64(0) ... 1000),
                    Gen.choose(in: UInt64(0) ... 1000),
                    Gen.choose(in: UInt64(0) ... 1000)
                )
                let value = (UInt64(redistributionCase.value[0]), UInt64(redistributionCase.value[1]), UInt64(redistributionCase.value[2]))
                reflected = try #require(try Interpreters.reflect(typed, with: value))
                generator = typed.erase()
                output = value
                property = { output in
                    let (first, second, third) = output as! (UInt64, UInt64, UInt64)
                    return fails([Double(first), Double(second), Double(third)]) == false
                }
            case .signed:
                let typed = Gen.zip(Gen.choose(in: Int64(-100) ... 100), Gen.choose(in: Int64(-100) ... 100))
                let value = (Int64(redistributionCase.value[0]), Int64(redistributionCase.value[1]))
                reflected = try #require(try Interpreters.reflect(typed, with: value))
                generator = typed.erase()
                output = value
                property = { output in
                    let (first, second) = output as! (Int64, Int64)
                    return fails([Double(first), Double(second)]) == false
                }
            case .mixed:
                let typed = Gen.zip(Gen.choose(in: UInt64(0) ... 1000), Gen.choose(in: 0.0 ... 1000.0))
                let value = (UInt64(redistributionCase.value[0]), redistributionCase.value[1])
                reflected = try #require(try Interpreters.reflect(typed, with: value))
                generator = typed.erase()
                output = value
                property = { output in
                    let (first, second) = output as! (UInt64, Double)
                    return fails([Double(first), second]) == false
                }
        }
        let built = ChoiceGraph.build(from: reflected)
        let found = ExchangeQuery.build(graph: built).compactMap { scope -> RedistributionScope? in
            guard case let .redistribution(redistributionScope) = scope else {
                return nil
            }
            return redistributionScope
        }
        let flattened = ChoiceSequence(reflected)
        tree = reflected
        graph = built
        sequence = flattened
        redistributionScope = try #require(found.first)
        scope = EncoderInput(
            transformation: GraphTransformation(operation: .exchange(.redistribution(redistributionScope)), priority: .zeroBenefit),
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
            ScopedRedistributionEncoder(tuning: ScopedReductionTuning()).reducer(redistributionScope, input: scope),
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
                encoderName: .redistribution,
                observer: { [weak recorder] in recorder?.record($0) }
            )
        )
        return ScopedRun(events: recorder.events, report: result.report, result: result)
    }
}
