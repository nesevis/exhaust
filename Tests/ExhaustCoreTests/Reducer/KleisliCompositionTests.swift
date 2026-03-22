import Testing
@testable import ExhaustCore

// MARK: - KleisliComposition Tests

@Suite("KleisliComposition")
struct KleisliCompositionTests {

    // MARK: - LegacyEncoderAdapter

    @Test("LegacyEncoderAdapter produces same probes as direct encoder call")
    func legacyAdapterProbeEquivalence() throws {
        let gen = Gen.arrayOf(
            Gen.choose(in: 0 ... 100 as ClosedRange<UInt64>),
            Gen.choose(in: 3 ... 3 as ClosedRange<UInt64>)
        )
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (_, tree) = try #require(try interpreter.next())
        let sequence = ChoiceSequence(tree)

        // Direct encoder call
        let allSpans = ChoiceSequence.extractAllValueSpans(from: sequence)
        var directEncoder = ZeroValueEncoder()
        directEncoder.start(sequence: sequence, targets: .spans(allSpans), convergedOrigins: nil)
        var directProbes: [ChoiceSequence] = []
        while let probe = directEncoder.nextProbe(lastAccepted: false) {
            directProbes.append(probe)
        }

        // Adapter call with full range
        let positionRange = 0 ... max(0, sequence.count - 1)
        var adapter = LegacyEncoderAdapter(inner: ZeroValueEncoder())
        adapter.start(
            sequence: sequence,
            tree: tree,
            positionRange: positionRange,
            context: ReductionContext()
        )
        var adapterProbes: [ChoiceSequence] = []
        while let probe = adapter.nextProbe(lastAccepted: false) {
            adapterProbes.append(probe)
        }

        #expect(
            directProbes.count == adapterProbes.count,
            "Probe count mismatch: direct=\(directProbes.count) adapter=\(adapterProbes.count)"
        )
        for (index, (direct, adapted)) in zip(directProbes, adapterProbes).enumerated() {
            #expect(direct == adapted, "Probe \(index) differs")
        }
    }

    @Test("LegacyEncoderAdapter filters spans to position range")
    func legacyAdapterFiltersToRange() throws {
        let gen = Gen.arrayOf(
            Gen.choose(in: 0 ... 100 as ClosedRange<UInt64>),
            Gen.choose(in: 5 ... 5 as ClosedRange<UInt64>)
        )
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (_, tree) = try #require(try interpreter.next())
        let sequence = ChoiceSequence(tree)

        let allSpans = ChoiceSequence.extractAllValueSpans(from: sequence)
        #expect(allSpans.count >= 3, "Expected at least 3 value spans")

        // Adapter with range covering only the first two value spans
        let restrictedRange = allSpans[0].range.lowerBound ... allSpans[1].range.upperBound
        var adapter = LegacyEncoderAdapter(inner: ZeroValueEncoder())
        adapter.start(
            sequence: sequence,
            tree: tree,
            positionRange: restrictedRange,
            context: ReductionContext()
        )
        var adapterProbes: [ChoiceSequence] = []
        while let probe = adapter.nextProbe(lastAccepted: false) {
            adapterProbes.append(probe)
        }

        // Full-range adapter for comparison
        var fullAdapter = LegacyEncoderAdapter(inner: ZeroValueEncoder())
        fullAdapter.start(
            sequence: sequence,
            tree: tree,
            positionRange: 0 ... max(0, sequence.count - 1),
            context: ReductionContext()
        )
        var fullProbes: [ChoiceSequence] = []
        while let probe = fullAdapter.nextProbe(lastAccepted: false) {
            fullProbes.append(probe)
        }

        #expect(
            adapterProbes.count <= fullProbes.count,
            "Restricted range should produce no more probes than full range"
        )
    }

    // MARK: - GeneratorLift

    @Test("GeneratorLift produces a fresh tree from a bind generator")
    func generatorLiftOnBindGenerator() throws {
        let gen = makeBoundArrayGen()
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (_, tree) = try #require(try interpreter.next())
        let sequence = ChoiceSequence(tree)

        let lift = GeneratorLift(gen: gen, mode: .guided(fallbackTree: tree))
        let result = lift.lift(sequence)

        #expect(result != nil, "Lift should succeed on a valid sequence")
        if let result {
            #expect(result.sequence.isEmpty == false, "Lifted sequence should be non-empty")
            #expect(result.liftReport != nil, "Guided mode should produce a lift report")
        }
    }

    @Test("GeneratorLift rejects an invalid sequence in exact mode")
    func generatorLiftRejectsInvalid() throws {
        let gen: ReflectiveGenerator<UInt64> = Gen.choose(in: 0 ... 10)
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (_, tree) = try #require(try interpreter.next())

        // Create a sequence with an out-of-range value
        var sequence = ChoiceSequence(tree)
        if let value = sequence[0].value {
            sequence[0] = .value(.init(
                choice: ChoiceValue(
                    value.choice.tag.makeConvertible(bitPattern64: 9_999_999),
                    tag: value.choice.tag
                ),
                validRange: value.validRange,
                isRangeExplicit: value.isRangeExplicit
            ))
        }

        let lift = GeneratorLift(gen: gen, mode: .exact)
        let result = lift.lift(sequence)
        #expect(result == nil, "Exact mode should reject out-of-range values")
    }

    // MARK: - KleisliComposition with Identity

    @Test("KleisliComposition with identity upstream produces no probes")
    func identityUpstreamProducesNoProbes() throws {
        let gen = Gen.arrayOf(
            Gen.choose(in: 0 ... 100 as ClosedRange<UInt64>),
            Gen.choose(in: 3 ... 3 as ClosedRange<UInt64>)
        )
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (_, tree) = try #require(try interpreter.next())
        let sequence = ChoiceSequence(tree)

        let fullRange = 0 ... max(0, sequence.count - 1)
        var composed = KleisliComposition(
            upstream: IdentityPointEncoder(),
            downstream: LegacyEncoderAdapter(inner: ZeroValueEncoder()),
            lift: GeneratorLift(gen: gen, mode: .exact),
            rollback: .atomic,
            upstreamRange: fullRange,
            downstreamRange: fullRange
        )
        composed.start(sequence: sequence, targets: .wholeSequence, convergedOrigins: nil)

        // Identity upstream returns nil immediately — nothing to lift
        let firstProbe = composed.nextProbe(lastAccepted: false)
        #expect(firstProbe == nil, "Identity upstream should produce no probes")
    }

    // MARK: - ReductionEdge

    @Test("reductionEdges returns edges for bind generators")
    func reductionEdgesForBindGenerator() throws {
        let gen = makeBoundArrayGen()
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (_, tree) = try #require(try interpreter.next())
        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)

        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)
        let edges = dag.reductionEdges()

        #expect(edges.isEmpty == false, "Bind generator should have at least one reduction edge")
        for edge in edges {
            #expect(
                edge.upstreamRange.lowerBound < edge.downstreamRange.lowerBound,
                "Upstream should precede downstream in the sequence"
            )
            #expect(
                edge.downstreamRange.upperBound <= max(0, sequence.count - 1),
                "Downstream range should be within sequence bounds"
            )
        }
    }

    @Test("reductionEdges returns empty for bind-free generators")
    func reductionEdgesEmptyForBindFree() throws {
        let gen = Gen.arrayOf(
            Gen.choose(in: 0 ... 100 as ClosedRange<UInt64>),
            Gen.choose(in: 3 ... 3 as ClosedRange<UInt64>)
        )
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (_, tree) = try #require(try interpreter.next())
        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)

        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)
        let edges = dag.reductionEdges()

        #expect(edges.isEmpty, "Bind-free generator should have no reduction edges")
    }
}

// MARK: - Helpers

private func makeBoundArrayGen() -> ReflectiveGenerator<Any> {
    let innerGen: ReflectiveGenerator<UInt64> = Gen.choose(in: 1 ... 10)
    let elementGen: ReflectiveGenerator<UInt64> = Gen.choose(in: 0 ... 100)

    return innerGen._bound(
        forward: { length in
            Gen.arrayOf(elementGen, Gen.choose(in: length ... length))
        },
        backward: { (output: [UInt64]) in
            UInt64(output.count)
        }
    ).erase()
}
