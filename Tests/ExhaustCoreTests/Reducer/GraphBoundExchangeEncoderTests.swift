import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Bound exchange characterisation")
struct GraphBoundExchangeEncoderTests {
    @Test("Exchange lifts joint midpoint proposals in order and reports only the source mutation", arguments: [true, false])
    func jointProposals(sinkIsBindInner: Bool) throws {
        let fixture = try ExchangeFixture(sinkIsBindInner: sinkIsBindInner)
        var attempts: [[ChoiceSequenceValue]] = []
        var encoder = BoundExchangeSearch.makeEncoder(lift: { candidate, _ in
            attempts.append(Array(candidate))
            return exchangeTree(candidate: candidate)
        })
        encoder.start(scope: fixture.scope)
        let probes = drain(&encoder, base: fixture.scope.baseSequence)
        let expected = fixture.expectedProposals()

        #expect(attempts == expected)
        #expect(probes.map(\.sequence) == expected)
        #expect(probes.map(\.mutation) == fixture.expectedMutations())
        #expect(encoder.ledger.constructedStages == 4)
    }

    @Test("Exchange locates either sink after the source subtree shifts its position", arguments: [true, false])
    func shiftedSink(sinkIsBindInner: Bool) throws {
        let fixture = try ExchangeFixture(sinkIsBindInner: sinkIsBindInner)
        var encoder = BoundExchangeSearch.makeEncoder(lift: { candidate, _ in
            exchangeTree(candidate: candidate, shiftedSource: true)
        })
        encoder.start(scope: fixture.scope)
        let probes = drain(&encoder, base: fixture.scope.baseSequence)
        let expected = fixture.expectedProposals().map { entries in
            Array(ChoiceSequence(exchangeTree(candidate: ChoiceSequence(entries), shiftedSource: true)))
        }

        #expect(probes.map(\.sequence) == expected)
        #expect(probes.map(\.mutation) == fixture.expectedMutations())
        #expect(encoder.ledger.constructedStages == 4)
    }

    @Test("Failed lifts spend attempts but do not consume the kept-lift budget")
    func failedLifts() throws {
        let fixture = try ExchangeFixture(sinkIsBindInner: true)
        var attempts = 0
        var encoder = BoundExchangeSearch.makeEncoder(lift: { candidate, _ in
            attempts += 1
            guard attempts > 2 else {
                return nil
            }
            return exchangeTree(candidate: candidate)
        })
        encoder.start(scope: fixture.scope)
        let probes = drain(&encoder, base: fixture.scope.baseSequence)

        #expect(attempts == 4)
        #expect(encoder.ledger.attempts == 4)
        #expect(probes.map(\.sequence) == Array(fixture.expectedProposals().suffix(2)))
        #expect(probes.map(\.mutation) == Array(fixture.expectedMutations().suffix(2)))
        #expect(encoder.ledger.constructedStages == 2)
    }

    @Test("A lift that loses the sink bind emits no probes", arguments: [true, false])
    func lostSink(sinkIsBindInner: Bool) throws {
        let fixture = try ExchangeFixture(sinkIsBindInner: sinkIsBindInner)
        var attempts = 0
        var encoder = BoundExchangeSearch.makeEncoder(lift: { _, _ in
            attempts += 1
            return .bind(fingerprint: 1, inner: .uint64(15, in: 0 ... 100), bound: .just)
        })
        encoder.start(scope: fixture.scope)

        #expect(drain(&encoder, base: fixture.scope.baseSequence).isEmpty)
        #expect(attempts == 4)
        #expect(encoder.ledger.constructedStages == 0)
    }

    @Test("A surviving sink must hold this proposal's raised value", arguments: [true, false])
    func changedSinkValue(sinkIsBindInner: Bool) throws {
        let fixture = try ExchangeFixture(sinkIsBindInner: sinkIsBindInner)
        var attempts = 0
        var encoder = BoundExchangeSearch.makeEncoder(lift: { _, fallback in
            attempts += 1
            return fallback
        })
        encoder.start(scope: fixture.scope)

        #expect(drain(&encoder, base: fixture.scope.baseSequence).isEmpty)
        #expect(attempts == 4)
        #expect(encoder.ledger.constructedStages == 0)
    }

    @Test("A bound-leaf sink is rejected when its bound range changes length")
    func changedBoundLength() throws {
        let fixture = try ExchangeFixture(sinkIsBindInner: false)
        var encoder = BoundExchangeSearch.makeEncoder(lift: { candidate, _ in
            let values = candidate.compactMap { $0.value?.choice.bitPattern64 }
            return .bind(
                fingerprint: 1,
                inner: .uint64(values[0], in: 0 ... 100),
                bound: .bind(
                    fingerprint: 2,
                    inner: .uint64(values[1], in: 0 ... 100),
                    bound: .group([.uint64(values[2], in: 0 ... 100), .just])
                )
            )
        })
        encoder.start(scope: fixture.scope)

        #expect(drain(&encoder, base: fixture.scope.baseSequence).isEmpty)
        #expect(encoder.ledger.constructedStages == 0)
    }

    @Test("Sink-value mismatch is distinct from a missing lifted bind", arguments: [true, false])
    func sinkFailureReasons(sinkIsBindInner: Bool) throws {
        let fixture = try ExchangeFixture(sinkIsBindInner: sinkIsBindInner)
        guard case let .exchange(.boundExchange(exchange)) = fixture.scope.transformation.operation else {
            Issue.record("Expected an exchange scope")
            return
        }
        var cursor = try #require(BoundExchangeProposalCursor(scope: fixture.scope, exchange: exchange))
        var prefix = fixture.scope.baseSequence
        let next = cursor.next(into: &prefix)
        let proposal = try #require(next)
        let unchanged = BoundExchangeSearch.buildDownstream(
            proposal: proposal,
            lifted: LiftResult(tree: fixture.scope.tree, sequence: fixture.scope.baseSequence),
            parent: fixture.scope,
            exchange: exchange
        )
        guard case .failed(.sinkValueMismatch) = unchanged else {
            Issue.record("A surviving sink with the wrong value must report a value mismatch")
            return
        }
        let missing = ChoiceTree.bind(fingerprint: 1, inner: .uint64(15, in: 0 ... 100), bound: .just)
        let lost = BoundExchangeSearch.buildDownstream(
            proposal: proposal,
            lifted: LiftResult(tree: missing, sequence: ChoiceSequence(missing)),
            parent: fixture.scope,
            exchange: exchange
        )
        guard case .failed(.bindNotFound) = lost else {
            Issue.record("A missing lifted sink bind must report that the bind was not found")
            return
        }
    }

    @Test("Signed exchange preserves semantic source and sink deltas")
    func signedExchangeDeltas() throws {
        let scope = try simpleExchangeScope(source: .int64(30), sink: .int64(5))
        var encoder = BoundExchangeSearch.makeEncoder(lift: { candidate, _ in simpleExchangeTree(candidate) })
        encoder.start(scope: scope)
        let probes = drain(&encoder, base: scope.baseSequence)
        let expected = zip([Int64(15), 23, 27, 29], [Int64(20), 12, 8, 6]).map { source, sink in
            Array(ChoiceSequence(ChoiceTree.bind(fingerprint: 1, inner: .int64(source), bound: .int64(sink))))
        }
        #expect(probes.map(\.sequence) == expected)
        #expect(encoder.ledger.attempts == 4)
        #expect(encoder.ledger.constructedStages == 4)
    }

    @Test("The exchange budget counts eight kept lifts rather than failed attempts")
    func keptLiftBudgetExcludesFailedAttempts() throws {
        let scope = try simpleExchangeScope(
            source: .uint64(65536, in: 0 ... 100_000),
            sink: .uint64(5, in: 0 ... 100_000)
        )
        var attempts = 0
        var encoder = BoundExchangeSearch.makeEncoder(lift: { candidate, _ in
            attempts += 1
            guard attempts > 2 else {
                return nil
            }
            return simpleExchangeTree(candidate)
        })
        encoder.start(scope: scope)
        let probes = drain(&encoder, base: scope.baseSequence)

        #expect(probes.count == 8)
        #expect(attempts == 10)
        #expect(encoder.ledger.attempts == 10)
        #expect(encoder.ledger.constructedStages == 8)
    }

    @Test("Refreshing after acceptance idles exchange without erasing its lift spend")
    func refreshRetainsSpend() throws {
        let fixture = try ExchangeFixture(sinkIsBindInner: true)
        var encoder = BoundExchangeSearch.makeEncoder(lift: { candidate, _ in exchangeTree(candidate: candidate) })
        encoder.start(scope: fixture.scope)
        var buffer = fixture.scope.baseSequence
        try #require(encoder.nextProbe(into: &buffer, lastAccepted: false) != nil)
        encoder.refreshState(graph: fixture.scope.graph, sequence: buffer)

        #expect(encoder.nextProbe(into: &buffer, lastAccepted: true) == nil)
        #expect(encoder.ledger.constructedStages == 1)
        #expect(encoder.ledger.attempts == 1)
        let reported = EncoderDispatch(encoder).liftMaterializations
        #expect(reported?.site == .boundExchangeLift)
        #expect(reported?.count == 1)
    }
}

// MARK: - Characterisation fixtures

private struct ExchangeProbe {
    let sequence: [ChoiceSequenceValue]
    let mutation: ProbeTraceRecorder.Mutation
}

private func drain(_ encoder: inout GraphComposedEncoder, base: ChoiceSequence) -> [ExchangeProbe] {
    var buffer = base
    var probes: [ExchangeProbe] = []
    while let mutation = encoder.nextProbe(into: &buffer, lastAccepted: false) {
        probes.append(ExchangeProbe(sequence: Array(buffer), mutation: .init(mutation)))
    }
    return probes
}

private func exchangeTree(candidate: ChoiceSequence, shiftedSource: Bool = false) -> ChoiceTree {
    let values = candidate.compactMap { $0.value?.choice.bitPattern64 }
    let source: ChoiceTree = shiftedSource
        ? .group([.just, .uint64(values[0], in: 0 ... 100)])
        : .uint64(values[0], in: 0 ... 100)
    return .bind(
        fingerprint: 1,
        inner: source,
        bound: .bind(
            fingerprint: 2,
            inner: .uint64(values[1], in: 0 ... 100),
            bound: .uint64(values[2], in: 0 ... 100)
        )
    )
}

private func simpleExchangeTree(_ candidate: ChoiceSequence) -> ChoiceTree? {
    let values = candidate.compactMap(\.value)
    guard values.count == 2 else {
        return nil
    }
    return .bind(
        fingerprint: 1,
        inner: .choice(values[0].choice, .init(
            validRange: values[0].validRange,
            isRangeExplicit: values[0].isRangeExplicit
        )),
        bound: .choice(values[1].choice, .init(
            validRange: values[1].validRange,
            isRangeExplicit: values[1].isRangeExplicit
        ))
    )
}

private func simpleExchangeScope(source: ChoiceTree, sink: ChoiceTree) throws -> EncoderInput {
    let tree = ChoiceTree.bind(fingerprint: 1, inner: source, bound: sink)
    let graph = ChoiceGraph.build(from: tree)
    let exchange = try #require(ExchangeQuery.build(graph: graph).compactMap { operation -> BoundExchangeScope? in
        guard case let .boundExchange(exchange) = operation else {
            return nil
        }
        return exchange
    }.first)
    return EncoderInput(
        transformation: GraphTransformation(
            operation: .exchange(.boundExchange(exchange)),
            priority: DispatchPriority(
                structuralBenefit: 0,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: 1
            )
        ),
        baseSequence: ChoiceSequence(tree),
        tree: tree,
        graph: graph,
        warmStartRecords: [:]
    )
}

private struct ExchangeFixture {
    let scope: EncoderInput
    let sourceNodeID: Int
    let sinkIsBindInner: Bool

    init(sinkIsBindInner: Bool) throws {
        self.sinkIsBindInner = sinkIsBindInner
        let tree = ChoiceTree.bind(
            fingerprint: 1,
            inner: .uint64(30, in: 0 ... 100),
            bound: .bind(
                fingerprint: 2,
                inner: .uint64(20, in: 0 ... 100),
                bound: .uint64(5, in: 0 ... 100)
            )
        )
        let graph = ChoiceGraph.build(from: tree)
        let sourceNodeID = try #require(graph.leafNodes.first)
        self.sourceNodeID = sourceNodeID
        let sinkLocation: SinkLocation = sinkIsBindInner ? .bindInner(bindNodeID: 2) : .boundLeaf(bindNodeID: 2)
        let exchange = try #require(ExchangeQuery.build(graph: graph).compactMap { operation -> BoundExchangeScope? in
            guard case let .boundExchange(exchange) = operation,
                  exchange.sourceLeafNodeID == sourceNodeID,
                  exchange.sinkLocation == sinkLocation
            else {
                return nil
            }
            return exchange
        }.first)
        scope = EncoderInput(
            transformation: GraphTransformation(
                operation: .exchange(.boundExchange(exchange)),
                priority: DispatchPriority(
                    structuralBenefit: 0,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: 1
                )
            ),
            baseSequence: ChoiceSequence(tree),
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        )
    }

    func expectedProposals() -> [[ChoiceSequenceValue]] {
        [UInt64(15), 23, 27, 29].map { source in
            let inner = sinkIsBindInner ? 20 + (30 - source) : 20
            let terminal = sinkIsBindInner ? 5 : 5 + (30 - source)
            return Array(ChoiceSequence(ChoiceTree.bind(
                fingerprint: 1,
                inner: .uint64(source, in: 0 ... 100),
                bound: .bind(
                    fingerprint: 2,
                    inner: .uint64(inner, in: 0 ... 100),
                    bound: .uint64(terminal, in: 0 ... 100)
                )
            )))
        }
    }

    func expectedMutations() -> [ProbeTraceRecorder.Mutation] {
        [UInt64(15), 23, 27, 29].map { value in
            .leafValues([.init(nodeID: sourceNodeID, value: ChoiceValue(value, tag: .uint64), mayReshape: true)])
        }
    }
}
