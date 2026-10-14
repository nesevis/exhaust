import Testing
@testable import ExhaustCore

@Suite("Scoped bound exchange encoder")
struct ScopedBoundExchangeEncoderTests {
    @Test("A sink pushed outside its regenerated range fails construction")
    func sinkMismatchIsRecorded() throws {
        let fixture = try BoundExchangeFixture(source: 30, sink: 25, boundOffset: 0)

        let report = fixture.run(property: { _ in true })

        #expect(report.buildOutcomes.contains { record, count in record.outcome == .failed(.sinkValueMismatch) && count > 0 })
        #expect(report.liftAttempts > report.constructedSearches)
    }
}

// MARK: - Fixture

/// A bind whose inner value is the exchange source and whose bound value is the sink, drawn from `0 ... source + boundOffset`.
private struct BoundExchangeFixture {
    let generator: AnyGenerator
    let tree: ChoiceTree
    let graph: ChoiceGraph
    let sequence: ChoiceSequence
    let exchange: BoundExchangeScope
    let sink: UInt64

    init(source: UInt64, sink: UInt64, boundOffset: UInt64) throws {
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
                inner: Gen.choose(in: UInt64(0) ... 100).erase()
            ),
            continuation: { .pure($0) }
        )
        tree = try #require(try Interpreters.reflect(generator, with: sink))
        graph = ChoiceGraph.build(from: tree)
        exchange = try #require(ExchangeQuery.build(graph: graph).compactMap { operation -> BoundExchangeScope? in
            guard case let .boundExchange(exchange) = operation else {
                return nil
            }
            return exchange
        }.first)
        sequence = ChoiceSequence(tree)
        self.sink = sink
    }

    func run(property: @escaping (Any) -> Bool) -> ScopedPassReport {
        let input = ScopedEncoderInput(baseSequence: sequence, tree: tree, graph: graph, warmStartRecords: [:])
        let result = ScopedReductionInterpreter.run(
            ScopedBoundExchangeEncoder(tuning: ScopedReductionTuning()).reducer(exchange, input: input),
            context: ScopedReductionInterpreter.Context(
                incumbent: ScopedCounterexample(
                    sequence: sequence,
                    tree: tree,
                    output: sink
                ),
                graph: graph,
                rejectCache: [],
                decoder: ScopedDecoder(
                    generator: generator,
                    property: property,
                    probeWrapper: nil,
                    hasBind: true
                ),
                encoderName: ScopedBoundExchangeEncoder.name
            )
        )
        return result.report
    }
}
