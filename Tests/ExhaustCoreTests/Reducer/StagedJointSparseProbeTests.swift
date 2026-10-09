import Testing
@testable import ExhaustCore

@Suite("Sparse staged joint probes")
struct StagedJointSparseProbeTests {
    @Test("Sparse hashes match complete candidate hashes across integer and floating tags", arguments: [
        TypeTag.int, .int8, .int16, .int32, .int64,
        .uint, .uint8, .uint16, .uint32, .uint64, .float16, .float, .double,
    ])
    func sparseHash(tag: TypeTag) {
        let values = tag.isFloatingPoint
            ? [75.0, 100.0, 0.0, 175.0].map { ChoiceValue($0, tag: tag) }
            : [UInt64(75), 100, 0, 125].map { ChoiceValue($0, tag: tag) }
        let tree = ChoiceTree.group(values.map { .choice($0, .init(validRange: tag.bitPatternRange, isRangeExplicit: true)) })
        let base = ChoiceSequence(tree)
        let leaves = NumericPairQuery.eligibleLeaves(graph: ChoiceGraph.build(from: tree))
        let hash = ZobristHash.hash(of: base)
        for arity in 2 ... 4 {
            let selected = Array(leaves.prefix(arity))
            let patterns = selected.map { leaf in NumericPairCandidates.values(for: leaf, simplifying: true).first ?? leaf.choice.bitPattern64 }
            let probe = StagedJointEncoder.Probe(leaves: selected, patterns: patterns)
            var candidate = base
            probe.write(into: &candidate)
            #expect(probe.hash(baseHash: hash, baseSequence: base) == ZobristHash.hash(of: candidate))
            #expect(base == ChoiceSequence(tree))
        }
    }

    @Test("Cache hits retain candidate order and accounting with and without tracing", arguments: [2, 3, 4], [false, true])
    func cachedStream(arity: Int, traced: Bool) throws {
        let fixture = try fixture(arity: arity)
        var reference = fixture.encoder
        var expected: [(sequence: ChoiceSequence, mutation: ProjectedMutation)] = []
        var candidate = fixture.state.sequence
        while let mutation = reference.nextProbe(into: &candidate, lastAccepted: false) {
            expected.append((candidate, mutation))
        }
        #expect(expected.count == 128)
        var state = fixture.state
        for index in expected.indices where index % 3 != 1 {
            state.rejectCache.insert(ZobristHash.hash(of: expected[index].sequence))
        }
        let cachedCount = expected.count { state.rejectCache.contains(ZobristHash.hash(of: $0.sequence)) }
        let recorder = ProbeTraceRecorder()
        let session = ProbeSession(
            encoder: fixture.encoder,
            transformation: fixture.scope.transformation,
            boundValueFingerprint: nil,
            baseSequence: state.sequence,
            hasBind: false,
            observer: traced ? { recorder.record($0) } : nil
        )
        let report = session.runToCompletion(state: &state)
        #expect(report.counts == ReductionProbeCounts(
            emitted: expected.count,
            rejectedByCache: cachedCount,
            propertyPassed: expected.count - cachedCount,
            materializationAttempts: expected.count - cachedCount
        ))
        #expect(state.sequence == fixture.state.sequence)
        if traced {
            let emissions = recorder.events.compactMap { event -> ProbeTraceRecorder.Event? in
                guard case .emitted = event else { return nil }
                return event
            }
            #expect(emissions == expected.enumerated().map { index, probe in
                .emitted(index + 1, Array(probe.sequence), .init(probe.mutation))
            })
        }
    }

    @Test("Uncached staged probes reuse storage across different scopes", arguments: [2, 3, 4])
    func bufferReuse(arity: Int) throws {
        var fixture = try fixture(arity: arity)
        var addresses: [UInt] = []
        let session = ProbeSession(
            encoder: fixture.encoder,
            transformation: fixture.scope.transformation,
            boundValueFingerprint: nil,
            baseSequence: fixture.state.sequence,
            hasBind: false,
            observer: { observation in
                guard case let .emitted(_, sequence, _) = observation else { return }
                addresses.append(sequence.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress!) })
            }
        )
        let report = session.runToCompletion(state: &fixture.state)
        #expect(report.probeCount == 128)
        #expect(Set(addresses).count == 1)
    }

    @Test("An acceptance after cached and passing probes commits the complete candidate and stops", arguments: [2, 3, 4])
    func acceptance(arity: Int) throws {
        let fixture = try fixture(arity: arity)
        var reference = fixture.encoder
        var candidate = fixture.state.sequence
        var first: ChoiceSequence?
        var witness: ChoiceSequence?
        for index in 0 ... 7 {
            #expect(reference.nextProbe(into: &candidate, lastAccepted: false) != nil)
            if index == 0 { first = candidate }
            if index == 7 { witness = candidate }
        }
        let expected = try #require(witness)
        let expectedValues = expected.compactMap { $0.value?.choice.bitPattern64 }
        let initialValues = fixture.state.sequence.compactMap { $0.value?.choice.bitPattern64 }
        var state = ProbeSessionFixtureState(
            sequence: fixture.state.sequence,
            tree: fixture.state.tree,
            output: fixture.state.output,
            graph: fixture.state.graph,
            gen: fixture.state.gen,
            property: { output in
                let values = output as! [UInt64]
                return values != expectedValues && values != initialValues
            }
        )
        try state.rejectCache.insert(ZobristHash.hash(of: #require(first)))
        let session = ProbeSession(
            encoder: fixture.encoder,
            transformation: fixture.scope.transformation,
            boundValueFingerprint: nil,
            baseSequence: state.sequence,
            hasBind: false
        )
        let report = session.runToCompletion(state: &state)
        #expect(report.probeCount == 8)
        #expect(report.cacheHitCount == 1)
        #expect(report.acceptCount == 1)
        #expect(state.sequence == expected)
        #expect(state.output as? [UInt64] == expectedValues)
    }

    private func fixture(arity: Int) throws -> (state: ProbeSessionFixtureState, scope: EncoderInput, encoder: EncoderDispatch) {
        let values: [UInt64] = [75, 100, 0, 125, 175, 225]
        let generator = Gen.eachOf(Array(repeating: Gen.choose(in: UInt64(0) ... 1000), count: values.count))
        let tree = try #require(try Interpreters.reflect(generator, with: values))
        var graph = ChoiceGraph.build(from: tree)
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            graph.convergenceStore[nodeID] = ConvergedOrigin(bound: metadata.value.bitPattern64, signal: .monotoneConvergence, configuration: .binarySearchSemanticSimplest, cycle: 0)
        }
        let gate = BoundValueGate(baseBudget: 15)
        let operation: GraphOperation
        if arity == 2 {
            operation = .exchange(.stagedNumericPairs(NumericPairQuery.build(graph: graph, gate: gate), probeBudget: 128))
        } else {
            let frontier = NumericJointQuery.frontier(graph: graph, gate: gate)
            let groups = NumericJointQuery.build(frontier: frontier, graph: graph, arity: arity, workLimit: Int.max, calculationLimit: 512, scopeLimit: 30).groups
            operation = .exchange(.numericJoint(groups, probeBudget: 128))
        }
        let sequence = ChoiceSequence(tree)
        let scope = EncoderInput(transformation: .init(operation: operation, priority: .zeroBenefit), baseSequence: sequence, tree: tree, graph: graph, warmStartRecords: [:])
        var encoder = EncoderDispatch.stagedJoint(StagedJointEncoder())
        encoder.start(scope: scope)
        let state = ProbeSessionFixtureState(sequence: sequence, tree: tree, output: values, graph: graph, gen: generator.erase(), property: { _ in true })
        return (state, scope, encoder)
    }
}
