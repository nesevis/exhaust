import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Scoped bound exchange parity")
struct ScopedBoundExchangeParityTests {
    @Test(
        "Scoped bound exchange reproduces the composed encoder's trace, accounting, and result",
        arguments: ExchangeCase.all
    )
    func parity(exchangeCase: ExchangeCase) throws {
        let fixture = try ScopedExchangeFixture(exchangeCase)
        let legacy = fixture.runLegacy()
        let scoped = fixture.runScoped()

        #expect(scoped.events == legacy.events)
        #expect(scoped.report.counts == legacy.report.counts)
        #expect(scoped.report.anyAccepted == legacy.report.anyAccepted)
        #expect(scoped.report.anyRequiresRebuild == legacy.report.anyRequiresRebuild)
        #expect(scoped.report.latestTreeIsStripped == legacy.report.latestTreeIsStripped)
        #expect(scoped.report.acceptedLeafNodeIDs == legacy.report.acceptedLeafNodeIDs)
        #expect(Set(scoped.report.searchReport.convergenceRecords.keys) == Set(legacy.report.convergenceRecords.keys))
        #expect(scoped.report.searchReport.hadUnresolvedReplacement == legacy.report.hadUnresolvedReplacement)
        #expect(scoped.report.constructedSearches == legacy.report.composedUpstreamLifts)
        #expect(scoped.report.liftAttempts == legacy.report.liftMaterializations?.count)
        #expect(legacy.report.liftMaterializations?.site == .boundExchangeLift)
        #expect(Array(scoped.result.incumbent.sequence) == Array(legacy.state.sequence))
        #expect(scoped.result.rejectCache == legacy.state.rejectCache)
    }

    @Test("The cases cover acceptance after rejections and an exhausted kept-lift budget")
    func casesCoverCompositionPaths() throws {
        let reports = try ExchangeCase.all.map { try ScopedExchangeFixture($0).runLegacy().report }

        #expect(reports.allSatisfy { report in report.probeCount > 0 })
        #expect(reports.contains { report in report.anyAccepted && report.probeCount > 1 })
        #expect(reports.contains { report in report.composedUpstreamLifts == BoundExchangeSearch.keptExchangeLiftBudget })
    }

    @Test("A sink pushed outside its regenerated range fails construction in both encoders")
    func sinkMismatchIsRecorded() throws {
        let fixture = try ScopedExchangeFixture(ExchangeCase(source: 30, sink: 25, boundOffset: 0, property: .alwaysPasses))
        let scoped = fixture.runScoped()

        #expect(scoped.report.buildFailures[.sinkValueMismatch, default: 0] > 0)
        #expect(scoped.report.liftAttempts > scoped.report.constructedSearches)
    }
}

// MARK: - Cases

/// One bound exchange scope and property. The bind's inner value is the exchange source and its bound value is the sink, drawn from `0 ... source + boundOffset`.
struct ExchangeCase: CustomStringConvertible, Sendable {
    enum Property: Sendable {
        case alwaysFails
        case alwaysPasses
        /// Fails only when the sink is at least the threshold, so some proposals are accepted and others rejected.
        case failsWhenSinkAtLeast(UInt64)
        /// Fails only when the sink is at most the threshold. Early proposals raise the sink most, so they pass and are rejected before a later, smaller raise is accepted.
        case failsWhenSinkAtMost(UInt64)

        var closure: @Sendable (Any) -> Bool {
            switch self {
                case .alwaysFails:
                    { _ in false }
                case .alwaysPasses:
                    { _ in true }
                case let .failsWhenSinkAtLeast(threshold):
                    { output in (output as! UInt64) < threshold }
                case let .failsWhenSinkAtMost(threshold):
                    { output in (output as! UInt64) > threshold }
            }
        }
    }

    let source: UInt64
    let sink: UInt64
    let boundOffset: UInt64
    var innerUpperBound: UInt64 = 100
    let property: Property

    var description: String {
        "source \(source), sink \(sink), offset \(boundOffset), inner ≤ \(innerUpperBound), \(property)"
    }

    static let all: [ExchangeCase] = [
        ExchangeCase(source: 30, sink: 5, boundOffset: 100, property: .alwaysFails),
        ExchangeCase(source: 30, sink: 5, boundOffset: 100, property: .alwaysPasses),
        ExchangeCase(source: 30, sink: 5, boundOffset: 100, property: .failsWhenSinkAtLeast(29)),
        ExchangeCase(source: 30, sink: 25, boundOffset: 0, property: .alwaysFails),
        ExchangeCase(source: 30, sink: 25, boundOffset: 0, property: .alwaysPasses),
        ExchangeCase(source: 90, sink: 3, boundOffset: 5, property: .failsWhenSinkAtLeast(60)),
        ExchangeCase(source: 30, sink: 5, boundOffset: 100, property: .failsWhenSinkAtMost(15)),
        ExchangeCase(source: 5000, sink: 7, boundOffset: 10000, innerUpperBound: 10000, property: .alwaysPasses),
        ExchangeCase(source: 5000, sink: 7, boundOffset: 10000, innerUpperBound: 10000, property: .failsWhenSinkAtMost(20)),
    ]
}

// MARK: - Fixture

/// Builds the same scope for the composed encoder and the scoped program, and runs each against its own copy of the state.
struct ScopedExchangeFixture {
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
    let exchange: BoundExchangeScope
    let scope: EncoderInput
    let property: (Any) -> Bool
    let output: UInt64

    init(_ exchangeCase: ExchangeCase) throws {
        let source = exchangeCase.source
        let boundOffset = exchangeCase.boundOffset
        let innerUpperBound = exchangeCase.innerUpperBound
        generator = AnyGenerator.impure(
            operation: .transform(
                kind: .bind(
                    fingerprint: 1,
                    forward: { input in
                        let inner = input as! UInt64
                        return Gen.choose(in: UInt64(0) ... inner + boundOffset).erase()
                    },
                    backward: { _ in source },
                    inputType: UInt64.self,
                    outputType: UInt64.self
                ),
                inner: Gen.choose(in: UInt64(0) ... innerUpperBound).erase()
            ),
            continuation: { .pure($0) }
        )
        tree = try #require(try Interpreters.reflect(generator, with: exchangeCase.sink))
        graph = ChoiceGraph.build(from: tree)
        exchange = try #require(ExchangeQuery.build(graph: graph).compactMap { operation -> BoundExchangeScope? in
            guard case let .boundExchange(exchange) = operation else {
                return nil
            }
            return exchange
        }.first)
        sequence = ChoiceSequence(tree)
        scope = EncoderInput(
            transformation: GraphTransformation(
                operation: .exchange(.boundExchange(exchange)),
                priority: .zeroBenefit
            ),
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        )
        property = exchangeCase.property.closure
        output = exchangeCase.sink
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
        var encoder = ChoiceGraphScheduler.makeBoundExchangeEncoder(gen: generator)
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
            ScopedBoundExchangeEncoder(tuning: ScopedReductionTuning()).reducer(exchange, input: scope),
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
                encoderName: .boundExchange,
                observer: { [weak recorder] in recorder?.record($0) }
            )
        )
        return ScopedRun(events: recorder.events, report: result.report, result: result)
    }
}
