import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Scoped bind pivot parity")
struct ScopedBindPivotParityTests {
    @Test(
        "Scoped bind pivot reproduces the composition's trace, accounting, and result",
        arguments: PivotProperty.allCases
    )
    func parity(property: PivotProperty) throws {
        let fixture = try PivotParityFixture(property: property)
        let legacy = fixture.runLegacy()
        let scoped = fixture.runScoped()

        #expect(scoped.events == legacy.events)
        #expect(scoped.report.counts == legacy.report.counts)
        #expect(scoped.report.anyAccepted == legacy.report.anyAccepted)
        #expect(scoped.report.anyRequiresRebuild == legacy.report.anyRequiresRebuild)
        #expect(scoped.report.latestTreeIsStripped == legacy.report.latestTreeIsStripped)
        #expect(scoped.report.acceptedLeafNodeIDs == legacy.report.acceptedLeafNodeIDs)
        #expect(legacy.report.composedUpstreamLifts == nil)
        #expect(legacy.report.liftMaterializations?.site == .bindPivotLift)
        #expect(scoped.report.liftAttempts == legacy.report.liftMaterializations?.count)
        #expect(Array(scoped.result.incumbent.sequence) == Array(legacy.state.sequence))
        #expect(scoped.result.rejectCache == legacy.state.rejectCache)
    }

    @Test("The properties cover an accepted pivot and a covering search that runs dry")
    func propertiesCoverPivotPaths() throws {
        let reports = try PivotProperty.allCases.map { try PivotParityFixture(property: $0).runLegacy().report }

        #expect(reports.contains { report in report.anyAccepted })
        #expect(reports.contains { report in report.anyAccepted == false && report.probeCount > 1 })
    }
}

// MARK: - Cases

/// Properties over the pivot fixture's `(count, value)` output.
enum PivotProperty: String, CaseIterable, Sendable {
    case alwaysFails
    case alwaysPasses
    /// Fails only when the regenerated value reaches two, which the covering search has to discover.
    case failsWhenValueAtLeastTwo

    var closure: @Sendable (Any) -> Bool {
        switch self {
            case .alwaysFails:
                { _ in false }
            case .alwaysPasses:
                { _ in true }
            case .failsWhenValueAtLeastTwo:
                { output in (output as! (UInt64, UInt64)).1 < 2 }
        }
    }
}

// MARK: - Fixture

/// A pick inside a bind's inner: `oneOf(just(3), 1)` bound to `choose(0 ... count)`, generated at `(1, 0)` so the pivot to the `just(3)` arm widens the bound range. Mirrors `ProbeSessionTraceTests`' pivot fixture.
struct PivotParityFixture {
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
    let pivotScope: BindPivotScope
    let scope: EncoderInput
    let property: (Any) -> Bool
    let output: (UInt64, UInt64)

    init(property pivotProperty: PivotProperty) throws {
        let typed = ReflectiveGenerator<UInt64>.oneOf(
            .just(3),
            Gen.zip(Gen.choose(in: UInt64(1) ... 1), Gen.choose(in: UInt64(0) ... 0))
                .map { first, _ in first }
                .wrapped(isReflective: true)
        ).bind { count in
            Gen.choose(in: UInt64(0) ... count)
                .map { (count, $0) }
                .wrapped(isReflective: false)
        }.gen
        let generated = try generate(typed, seed: 6)
        try #require(generated.value == (UInt64(1), UInt64(0)))
        guard case let .success(_, materialized, _) = Materializer.materializeAny(
            typed.erase(),
            context: .init(
                prefix: ChoiceSequence(generated.tree),
                mode: .exact,
                fallbackTree: generated.tree,
                materializePicks: true
            )
        ) else {
            throw PivotParityFixtureError.materializationFailed
        }
        let built = ChoiceGraph.build(from: materialized)
        let pivot = try #require(MinimizationQuery.deferredScopes(graph: built, stopAtFirst: false).compactMap { operation -> BindPivotScope? in
            guard case let .bindPivot(pivot) = operation else {
                return nil
            }
            return pivot
        }.first)
        let flattened = ChoiceSequence(materialized)
        generator = typed.erase()
        tree = materialized
        graph = built
        sequence = flattened
        pivotScope = pivot
        scope = EncoderInput(
            transformation: GraphTransformation(
                operation: .minimize(.bindPivot(pivot)),
                priority: .zeroBenefit
            ),
            baseSequence: flattened,
            tree: materialized,
            graph: built,
            warmStartRecords: [:]
        )
        property = pivotProperty.closure
        output = (UInt64(1), UInt64(0))
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
        var encoder = ChoiceGraphScheduler.makeBindPivotEncoder(gen: generator)
        encoder.start(scope: scope)
        let session = ProbeSession(
            encoder: encoder,
            transformation: scope.transformation,
            boundValueFingerprint: nil,
            baseSequence: sequence,
            hasBind: true,
            observer: { [weak recorder] in recorder?.record($0) }
        )
        let report = session.runToCompletion(state: &state)
        return LegacyRun(events: recorder.events, report: report, state: state)
    }

    func runScoped() -> ScopedRun {
        let recorder = ProbeTraceRecorder()
        let result = ScopedReductionInterpreter.run(
            ScopedBindPivotEncoder(tuning: ScopedReductionTuning()).reducer(pivotScope, input: scope),
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
                    hasBind: true
                ),
                encoderName: .bindPivot,
                observer: { [weak recorder] in recorder?.record($0) }
            )
        )
        return ScopedRun(events: recorder.events, report: result.report, result: result)
    }
}

private enum PivotParityFixtureError: Error {
    case materializationFailed
}
