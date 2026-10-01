import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Probe session characterisation")
struct ProbeSessionTraceTests {
    @Test("Records emitted choices and cache rejection without selecting a decoder")
    func cacheRejection() throws {
        var fixture = try Fixture(property: { _ in true })
        fixture.state.rejectCache.insert(ZobristHash.hash(of: ChoiceSequence(choices(2))))
        let recorder = ProbeTraceRecorder()
        var session = fixture.session(recorder: recorder)
        _ = try session.step(state: &fixture.state)

        #expect(recorder.events == [
            emission(1, value: 2),
            .terminated(1, .cacheRejected, materializationAttempts: 0),
        ])
        #expect(session.counts.rejectedByCache == 1)
    }

    @Test("Keeps all passing probes in proposal order with their decoder costs")
    func propertyPasses() throws {
        var fixture = try Fixture(property: { _ in true })
        let recorder = ProbeTraceRecorder()
        var session = fixture.session(recorder: recorder)
        let report = try session.runToCompletion(state: &fixture.state)

        #expect(recorder.events == [
            emission(1, value: 2),
            selection(1),
            .terminated(1, .propertyPassed, materializationAttempts: 1),
            emission(2, value: 0),
            selection(2),
            .terminated(2, .propertyPassed, materializationAttempts: 1),
            emission(3, value: 3),
            selection(3),
            .terminated(3, .propertyPassed, materializationAttempts: 1),
        ])
        #expect(report.probeCount == 3)
        #expect(report.counts.materializationAttempts == 3)
    }

    @Test("Records decoded choices even when the session rejects an enlarging exact result")
    func enlargingCommit() throws {
        var fixture = try Fixture(property: { _ in false })
        let recorder = ProbeTraceRecorder()
        var session = fixture.session(recorder: recorder)
        _ = try session.step(state: &fixture.state)
        _ = try session.step(state: &fixture.state)

        #expect(recorder.events == [
            emission(1, value: 2),
            selection(1),
            .decoded(1, choices(2)),
            .terminated(1, .propertyFailedNotAdmitted(.enlargingCommit), materializationAttempts: 2),
        ])
        #expect(Array(fixture.state.sequence) == choices(1))
        #expect(session.anyAccepted == false)
    }

    @Test("Records the actual commit separately from a preceding property failure")
    func acceptedCommit() throws {
        var fixture = try Fixture(property: { _ in false })
        let recorder = ProbeTraceRecorder()
        var session = fixture.session(recorder: recorder)
        for _ in 0 ..< 4 {
            _ = try session.step(state: &fixture.state)
        }

        #expect(recorder.events == [
            emission(1, value: 2),
            selection(1),
            .decoded(1, choices(2)),
            .terminated(1, .propertyFailedNotAdmitted(.enlargingCommit), materializationAttempts: 2),
            emission(2, value: 0),
            selection(2),
            .decoded(2, choices(0)),
            .terminated(2, .accepted, materializationAttempts: 2),
        ])
        #expect(Array(fixture.state.sequence) == choices(0))
        #expect(session.anyAccepted)
    }

    @Test("Records materialization rejection without claiming the property ran")
    func materializationRejection() throws {
        var fixture = try Fixture(property: { _ in
            Issue.record("A rejected materialization must not invoke the property")
            return false
        })
        fixture.state.gen = Gen.choose(in: UInt64(0) ... 1).erase()
        let recorder = ProbeTraceRecorder()
        var session = fixture.session(recorder: recorder)
        _ = try session.step(state: &fixture.state)
        _ = try session.step(state: &fixture.state)

        #expect(recorder.events == [
            emission(1, value: 2),
            selection(1),
            .terminated(1, .materializationRejected, materializationAttempts: 1),
        ])
        #expect(session.counts.propertyInvocations == 0)
    }

    @Test("An accepting composition discards suspended stages but retains its spent-work counters")
    func compositionAcceptanceDiscardsSuspendedStages() throws {
        var fixture = try Fixture(property: { ($0 as? UInt64) != 0 })
        let downstream = try Fixture(value: 2, property: { _ in true })
        let recorder = ProbeTraceRecorder()
        var encoder = EncoderDispatch.composed(GraphComposedEncoder(
            name: .composed,
            makeProposals: domainLeafProposals,
            policy: CompositionPolicy(
                stageBudget: 2,
                chainLimits: NestedChainLimits(
                    probesPerStageTurn: 1,
                    maxBuildsPerStart: 2,
                    buildPool: CompositionBuildPool(capacity: 2)
                )
            ),
            lift: { _, fallbackTree in fallbackTree },
            downstreamFactory: { _, _, _ in
                .stage(encoder: .composed(domainFixtureEncoder()), scope: downstream.scope)
            }
        ))
        encoder.start(scope: fixture.scope)
        var session = ProbeSession(
            encoder: encoder,
            transformation: fixture.scope.transformation,
            boundValueFingerprint: nil,
            baseSequence: fixture.state.sequence,
            hasBind: false,
            observer: { [weak recorder] in recorder?.record($0) }
        )
        let report = try session.runToCompletion(state: &fixture.state)

        #expect(recorder.events == [
            composedEmission(1, value: 3, upstream: 2),
            reshapeSelection(1),
            .terminated(1, .propertyPassed, materializationAttempts: 1),
            composedEmission(2, value: 3, upstream: 0),
            .terminated(2, .cacheRejected, materializationAttempts: 0),
            composedEmission(3, value: 1, upstream: 2),
            reshapeSelection(3),
            .terminated(3, .propertyPassed, materializationAttempts: 1),
            composedEmission(4, value: 1, upstream: 0),
            .terminated(4, .cacheRejected, materializationAttempts: 0),
            composedEmission(5, value: 0, upstream: 2),
            reshapeSelection(5),
            .decoded(5, choices(0)),
            .terminated(5, .accepted, materializationAttempts: 2),
        ])
        #expect(report.composedUpstreamLifts == 2)
        #expect(report.probeCount == 5)
        #expect(report.anyRequiresRebuild)
        guard case .finished = try session.step(state: &fixture.state) else {
            Issue.record("An accepted composition must remain finished")
            return
        }
        #expect(recorder.events.count == 14)
    }

    @Test("A guided bind pivot commits its first lifted probe and finishes through graph application")
    func pivotAcceptanceFinishesSession() throws {
        var fixture = try pivotFixture()
        let recorder = ProbeTraceRecorder()
        var encoder = ChoiceGraphScheduler.makeBindPivotEncoder(gen: fixture.state.gen)
        encoder.start(scope: fixture.scope)
        var session = ProbeSession(
            encoder: encoder,
            transformation: fixture.scope.transformation,
            boundValueFingerprint: nil,
            baseSequence: fixture.state.sequence,
            hasBind: true,
            observer: { [weak recorder] in recorder?.record($0) }
        )
        let report = try session.runToCompletion(state: &fixture.state)
        let expected = fixture.liftedChoices

        #expect(recorder.events == [
            .emitted(1, expected, .branchSelected(fixture.pickNodeID, 0)),
            .decoderSelected(1, preferExact: false, materializePicks: true),
            .decoded(1, expected),
            .terminated(1, .accepted, materializationAttempts: 2),
        ])
        #expect(Array(fixture.state.sequence) == expected)
        #expect(report.anyRequiresRebuild)
        #expect(report.liftMaterializations?.count == 1)
        #expect(report.probeCount == 1)
        guard case .finished = try session.step(state: &fixture.state) else {
            Issue.record("An accepted pivot must remain finished")
            return
        }
        #expect(recorder.events.count == 4)
    }

    @Test("An accepted sibling swap continues into its adaptive extension")
    func swapExtensionRunsAfterAcceptance() throws {
        let generator = Gen.zip(
            Gen.choose(in: UInt64(0) ... 3),
            Gen.choose(in: UInt64(0) ... 3),
            Gen.choose(in: UInt64(0) ... 3),
            Gen.choose(in: UInt64(0) ... 3)
        )
        let tree = try #require(try Interpreters.reflect(generator, with: (UInt64(3), UInt64(0), UInt64(0), UInt64(0))))
        let pushedTree = try #require(try Interpreters.reflect(generator, with: (UInt64(0), UInt64(0), UInt64(0), UInt64(3))))
        let graph = ChoiceGraph.build(from: tree)
        let permutation = try #require(PermutationQuery.build(graph: graph).first)
        let scope = EncoderInput(
            transformation: GraphTransformation(
                operation: .permute(permutation),
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
        var state = TraceState(
            sequence: ChoiceSequence(tree),
            tree: tree,
            graph: graph,
            gen: generator.erase(),
            property: { _ in false }
        )
        var encoder = EncoderDispatch.swap(GraphSwapEncoder())
        encoder.start(scope: scope)
        var session = ProbeSession(
            encoder: encoder,
            transformation: scope.transformation,
            boundValueFingerprint: nil,
            baseSequence: state.sequence,
            hasBind: false
        )
        let report = try session.runToCompletion(state: &state)

        try #require(report.anyAccepted)
        #expect(report.probeCount > 1)
        #expect(state.sequence == ChoiceSequence(pushedTree))
    }

    @Test("A guided property failure with no admitted reduction has no decoded-choice event")
    func guidedAdmissionRejection() throws {
        var fixture = try pivotFixture()
        let recorder = ProbeTraceRecorder()
        let original = fixture.scope.tree
        var encoder = EncoderDispatch.composed(BindPivotSearch.makeEncoder(lift: { _, _ in original }))
        encoder.start(scope: fixture.scope)
        var session = ProbeSession(
            encoder: encoder,
            transformation: fixture.scope.transformation,
            boundValueFingerprint: nil,
            baseSequence: fixture.state.sequence,
            hasBind: true,
            observer: { [weak recorder] in recorder?.record($0) }
        )
        _ = try session.step(state: &fixture.state)
        _ = try session.step(state: &fixture.state)

        #expect(recorder.events == [
            .emitted(1, Array(fixture.scope.baseSequence), .branchSelected(fixture.pickNodeID, 0)),
            .decoderSelected(1, preferExact: false, materializePicks: true),
            .terminated(1, .propertyFailedNotAdmitted(.decoderReturnedNoReduction), materializationAttempts: 2),
        ])
        #expect(session.anyAccepted == false)
    }

    @Test("A real bound exchange lifts jointly, decodes exactly, and idles after acceptance")
    func realExchangeAcceptance() throws {
        let generator = AnyGenerator.impure(
            operation: .transform(
                kind: .bind(
                    fingerprint: 1,
                    forward: { input in
                        let source = input as! UInt64
                        return Gen.choose(in: UInt64(0) ... source + 100).erase()
                    },
                    backward: { _ in UInt64(30) },
                    inputType: UInt64.self,
                    outputType: UInt64.self
                ),
                inner: Gen.choose(in: UInt64(0) ... 100).erase()
            ),
            continuation: { .pure($0) }
        )
        let tree = try #require(try Interpreters.reflect(generator, with: UInt64(5)))
        let graph = ChoiceGraph.build(from: tree)
        let exchange = try #require(ExchangeQuery.build(graph: graph).compactMap { operation -> BoundExchangeScope? in
            guard case let .boundExchange(exchange) = operation else {
                return nil
            }
            return exchange
        }.first)
        let sequence = ChoiceSequence(tree)
        let scope = EncoderInput(
            transformation: GraphTransformation(
                operation: .exchange(.boundExchange(exchange)),
                priority: DispatchPriority(
                    structuralBenefit: 0,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: 1
                )
            ),
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        )
        var state = TraceState(
            sequence: sequence,
            tree: tree,
            output: UInt64(5),
            graph: graph,
            gen: generator,
            property: { _ in false }
        )
        let recorder = ProbeTraceRecorder()
        var encoder = ChoiceGraphScheduler.makeBoundExchangeEncoder(gen: generator)
        encoder.start(scope: scope)
        var session = ProbeSession(
            encoder: encoder,
            transformation: scope.transformation,
            boundValueFingerprint: nil,
            baseSequence: sequence,
            hasBind: true,
            observer: { [weak recorder] in recorder?.record($0) }
        )
        let report = try session.runToCompletion(state: &state)
        let expected: [ChoiceSequenceValue] = [
            .bind(true),
            .value(.init(choice: ChoiceValue(UInt64(15), tag: .uint64), validRange: 0 ... 100, isRangeExplicit: true)),
            .value(.init(choice: ChoiceValue(UInt64(20), tag: .uint64), validRange: 0 ... 115, isRangeExplicit: true)),
            .bind(false),
        ]

        #expect(recorder.events == [
            .emitted(1, expected, .leafValues([
                .init(nodeID: exchange.sourceLeafNodeID, value: ChoiceValue(UInt64(15), tag: .uint64), mayReshape: true),
            ])),
            .decoderSelected(1, preferExact: true, materializePicks: true),
            .decoded(1, expected),
            .terminated(1, .accepted, materializationAttempts: 2),
        ])
        #expect(report.composedUpstreamLifts == 1)
        #expect(report.liftMaterializations?.site == .boundExchangeLift)
        #expect(report.liftMaterializations?.count == 1)
        #expect(report.probeCount == 1)
        #expect(report.anyRequiresRebuild)
        #expect(Array(state.sequence) == expected)
    }

    @Test("A report with a pending probe records interruption exactly once")
    func pendingProbeInterrupted() throws {
        var fixture = try Fixture(property: { _ in true })
        let recorder = ProbeTraceRecorder()
        var session = fixture.session(recorder: recorder)
        _ = try session.step(state: &fixture.state)
        _ = session.report()
        _ = session.report()

        #expect(recorder.events == [
            emission(1, value: 2),
            selection(1),
            .terminated(1, .interrupted, materializationAttempts: 0),
        ])
    }

    @Test("Lifted operations retain their decoder and acceptance policies")
    func separateDecoderAndAcceptanceContracts() {
        let encoders: [(EncoderDispatch, Bool, AcceptanceHandling)] = [
            (.composed(BoundExchangeSearch.makeEncoder(lift: { _, _ in nil })), true, .refreshAndIdle),
            (.composed(BindPivotSearch.makeEncoder(lift: { _, _ in nil })), false, .applyMutation),
            (.binarySearch(GraphBinarySearchEncoder()), false, .applyMutation),
        ]
        for (encoder, requiresExact, acceptance) in encoders {
            #expect(encoder.requiresExactDecoder == requiresExact)
            #expect(encoder.acceptanceHandling == acceptance)
            let selection = ChoiceGraphScheduler.selectDecoder(
                for: .branchSelected(pickNodeID: 0, newSelectedID: 1),
                requiresExactDecoder: encoder.requiresExactDecoder,
                hasBind: true
            )
            #expect(selection.preferExact == requiresExact)
            #expect(selection.materializePicks)
            let valueSelection = ChoiceGraphScheduler.selectDecoder(
                for: .leafValues([
                    LeafChange(leafNodeID: 0, newValue: ChoiceValue(UInt64(0), tag: .uint64), mayReshape: false),
                ]),
                requiresExactDecoder: encoder.requiresExactDecoder,
                hasBind: true
            )
            #expect(valueSelection.preferExact)
            #expect(valueSelection.materializePicks == false)
        }
    }

    @Test("Composition policy controls decoding and acceptance independently of the operation name")
    func mixedCompositionContracts() {
        let policies: [(Bool, AcceptanceHandling)] = [
            (true, .applyMutation),
            (false, .refreshAndIdle),
            (true, .refreshAndIdle),
            (false, .applyMutation),
        ]
        for name in [EncoderName.composed, .bindPivot, .boundExchange] {
            for (requiresExact, acceptance) in policies {
                let encoder = EncoderDispatch.composed(GraphComposedEncoder(
                    name: name,
                    makeProposals: { _ in nil },
                    policy: CompositionPolicy(
                        requiresExactDecoder: requiresExact,
                        acceptanceHandling: acceptance
                    ),
                    lift: { _, _ in nil },
                    downstreamFactory: { _, _, _ in .failed(.bindNotFound) }
                ))
                #expect(encoder.name == name)
                #expect(encoder.requiresExactDecoder == requiresExact)
                #expect(encoder.acceptanceHandling == acceptance)
                let selection = ChoiceGraphScheduler.selectDecoder(
                    for: .branchSelected(pickNodeID: 0, newSelectedID: 1),
                    requiresExactDecoder: encoder.requiresExactDecoder,
                    hasBind: true
                )
                #expect(selection.preferExact == requiresExact)
                #expect(selection.materializePicks)
            }
        }
    }

    @Test("Installing an observer does not change search counters or the committed sequence")
    func observationPreservesSearch() throws {
        var observed = try Fixture(property: { _ in false })
        var unobserved = try Fixture(property: { _ in false })
        let recorder = ProbeTraceRecorder()
        var observedSession = observed.session(recorder: recorder)
        var unobservedSession = unobserved.session()
        let observedReport = try observedSession.runToCompletion(state: &observed.state)
        let unobservedReport = try unobservedSession.runToCompletion(state: &unobserved.state)

        #expect(Array(observed.state.sequence) == Array(unobserved.state.sequence))
        #expect(observedReport.probeCount == unobservedReport.probeCount)
        #expect(observedReport.acceptCount == unobservedReport.acceptCount)
        #expect(observedReport.cacheHitCount == unobservedReport.cacheHitCount)
        #expect(observedReport.counts.materializationAttempts == unobservedReport.counts.materializationAttempts)
        #expect(observedReport.anyRequiresRebuild == unobservedReport.anyRequiresRebuild)
    }
}

// MARK: - Characterisation fixtures

private func choices(_ value: UInt64) -> [ChoiceSequenceValue] {
    [
        .value(.init(
            choice: ChoiceValue(value, tag: .uint64),
            validRange: 0 ... 3,
            isRangeExplicit: true
        )),
    ]
}

private func emission(_ probeID: Int, value: UInt64) -> ProbeTraceRecorder.Event {
    .emitted(probeID, choices(value), .leafValues([
        .init(nodeID: 0, value: ChoiceValue(value, tag: .uint64), mayReshape: true),
    ]))
}

private func selection(_ probeID: Int) -> ProbeTraceRecorder.Event {
    .decoderSelected(probeID, preferExact: true, materializePicks: true)
}

private func composedEmission(_ probeID: Int, value: UInt64, upstream: UInt64) -> ProbeTraceRecorder.Event {
    .emitted(probeID, choices(value), .leafValues([
        .init(nodeID: 0, value: ChoiceValue(upstream, tag: .uint64), mayReshape: true),
    ]))
}

private func reshapeSelection(_ probeID: Int) -> ProbeTraceRecorder.Event {
    .decoderSelected(probeID, preferExact: true, materializePicks: true)
}

private struct TraceState: ProbeSessionState {
    var sequence: ChoiceSequence
    var tree: ChoiceTree
    var output: Any = UInt64(1)
    var graph: ChoiceGraph
    var gen: AnyGenerator
    let property: (Any) -> Bool
    let probeWrapper: ProbeWrapper? = nil
    var rejectCache: Set<UInt64> = []
    let collectStats = true
    let isInstrumented = false
}

private struct PivotFixture {
    var state: TraceState
    let scope: EncoderInput
    let pickNodeID: Int
    let liftedChoices: [ChoiceSequenceValue]
}

private func pivotFixture() throws -> PivotFixture {
    let generator = ReflectiveGenerator<UInt64>.oneOf(
        .just(3),
        Gen.zip(Gen.choose(in: UInt64(1) ... 1), Gen.choose(in: UInt64(0) ... 0))
            .map { first, _ in first }
            .wrapped(isReflective: true)
    ).bind { count in
        Gen.choose(in: UInt64(0) ... count)
            .map { (count, $0) }
            .wrapped(isReflective: false)
    }.gen
    let generated = try generate(generator, seed: 6)
    try #require(generated.value == (UInt64(1), UInt64(0)))
    let reflected = generated.tree
    guard case let .success(_, tree, _) = Materializer.materializeAny(
        generator.erase(),
        context: .init(
            prefix: ChoiceSequence(reflected),
            mode: .exact,
            fallbackTree: reflected,
            materializePicks: true
        )
    ) else {
        throw PivotFixtureError.materializationFailed
    }
    let graph = ChoiceGraph.build(from: tree)
    let pivots = MinimizationQuery.deferredScopes(graph: graph, stopAtFirst: false)
    let pivot = try #require(pivots.compactMap { operation -> BindPivotScope? in
        guard case let .bindPivot(pivot) = operation else {
            return nil
        }
        return pivot
    }.first)
    guard case let .pick(metadata) = graph.nodes[pivot.pickNodeID].kind else {
        throw PivotFixtureError.missingPick
    }
    let sequence = ChoiceSequence(tree)
    let scope = EncoderInput(
        transformation: GraphTransformation(
            operation: .minimize(.bindPivot(pivot)),
            priority: DispatchPriority(
                structuralBenefit: 0,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: 1
            )
        ),
        baseSequence: sequence,
        tree: tree,
        graph: graph,
        warmStartRecords: [:]
    )
    return PivotFixture(
        state: TraceState(
            sequence: sequence,
            tree: tree,
            output: (UInt64(1), UInt64(0)),
            graph: graph,
            gen: generator.erase(),
            property: { _ in false }
        ),
        scope: scope,
        pickNodeID: pivot.pickNodeID,
        liftedChoices: [
            .bind(true),
            .group(true),
            .branch(.init(id: 0, branchCount: 2, fingerprint: metadata.fingerprint)),
            .just,
            .group(false),
            .value(.init(choice: ChoiceValue(UInt64(0), tag: .uint64), validRange: 0 ... 3, isRangeExplicit: true)),
            .bind(false),
        ]
    )
}

private enum PivotFixtureError: Error {
    case materializationFailed
    case missingPick
}

private struct Fixture {
    var state: TraceState
    let scope: EncoderInput

    init(value: UInt64 = 1, property: @escaping (Any) -> Bool) throws {
        let generator = Gen.choose(in: UInt64(0) ... 3)
        let tree = try #require(try Interpreters.reflect(generator, with: value))
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let minimization = try #require(MinimizationQuery.build(graph: graph).first)
        let transformation = GraphTransformation(
            operation: .minimize(minimization),
            priority: DispatchPriority(
                structuralBenefit: 0,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: 1
            )
        )
        scope = EncoderInput(
            transformation: transformation,
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        )
        state = TraceState(sequence: sequence, tree: tree, graph: graph, gen: generator.erase(), property: property)
    }

    func session(recorder: ProbeTraceRecorder? = nil) -> ProbeSession {
        var encoder = EncoderDispatch.composed(domainFixtureEncoder())
        encoder.start(scope: scope)
        return ProbeSession(
            encoder: encoder,
            transformation: scope.transformation,
            boundValueFingerprint: nil,
            baseSequence: state.sequence,
            hasBind: false,
            observer: recorder.map { recorder in
                { [weak recorder] observation in recorder?.record(observation) }
            }
        )
    }
}
