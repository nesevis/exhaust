import Testing
@testable import ExhaustCore

@Suite("Sibling swap extension")
struct SwapExtensionTests {
    @Test("A rejected doubling probe bisects from the last accepted sequence, not the rejected one")
    func bisectionBuildsFromAcceptedSequence() throws {
        // Fails while the 3 sits at index 2 or lower, so doubling to index 3 is rejected and bisection lands on index 2.
        var fixture = try SwapFixture(
            generator: fourValues(),
            value: (UInt64(3), UInt64(0), UInt64(0), UInt64(0))
        ) { value in
            guard let values = value as? (UInt64, UInt64, UInt64, UInt64) else {
                return true
            }
            return [values.0, values.1, values.2, values.3].firstIndex(of: 3)! > 2
        }
        let report = try fixture.run()

        let output = try #require(fixture.state.output as? (UInt64, UInt64, UInt64, UInt64))
        #expect(output == (0, 0, 3, 0))
        #expect(report.probeCount == 3)
    }

    @Test("A rejected bisection midpoint narrows the search instead of being proposed again")
    func rejectedMidpointNarrowsBisection() throws {
        // Fails only while the 3 sits at index 1 or lower: the initial swap is accepted, then doubling to index 3 and the midpoint at index 2 are both rejected.
        var fixture = try SwapFixture(
            generator: fourValues(),
            value: (UInt64(3), UInt64(0), UInt64(0), UInt64(0))
        ) { value in
            guard let values = value as? (UInt64, UInt64, UInt64, UInt64) else {
                return true
            }
            return [values.0, values.1, values.2, values.3].firstIndex(of: 3)! > 1
        }
        let report = try fixture.run()

        // Re-proposing a rejected midpoint hits the reject cache without decoding, so an unbounded session would spin forever.
        #expect(fixture.sessionFinished)

        let output = try #require(fixture.state.output as? (UInt64, UInt64, UInt64, UInt64))
        #expect(output == (0, 3, 0, 0))
        #expect(report.probeCount == 3)
    }

    @Test("Extension probes stay aligned when swapped siblings differ in width")
    func slotRangesFollowSwappedWidths() throws {
        let inner = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 3), within: 1 ... 2)
        let sibling = Gen.arrayOf(inner, exactly: 1)
        let generator = Gen.zip(sibling, sibling, sibling, sibling)
        let wide: [[UInt64]] = [[3, 3]]
        let narrow: [[UInt64]] = [[0]]
        // Fails while the wide sibling sits at index 2 or lower. After the initial swap every slot past index 0 has moved, so a probe built from the dispatch-time ranges would cut entries mid-sibling.
        var fixture = try SwapFixture(
            generator: generator,
            value: (wide, narrow, narrow, narrow)
        ) { value in
            guard let values = value as? ([[UInt64]], [[UInt64]], [[UInt64]], [[UInt64]]) else {
                return true
            }
            return [values.0, values.1, values.2, values.3].firstIndex(of: wide)! > 2
        }
        try #require(fixture.swappableGroupSize == 4)
        _ = try fixture.run()

        let output = try #require(fixture.state.output as? ([[UInt64]], [[UInt64]], [[UInt64]], [[UInt64]]))
        #expect([output.0, output.1, output.2, output.3] == [narrow, narrow, wide, narrow])
    }
}

// MARK: - Fixtures

private func fourValues() -> Generator<(UInt64, UInt64, UInt64, UInt64)> {
    Gen.zip(
        Gen.choose(in: UInt64(0) ... 3),
        Gen.choose(in: UInt64(0) ... 3),
        Gen.choose(in: UInt64(0) ... 3),
        Gen.choose(in: UInt64(0) ... 3)
    )
}

private struct SwapFixture {
    var state: SwapSessionState
    let scope: EncoderInput
    private(set) var sessionFinished = false

    var swappableGroupSize: Int {
        guard case let .permute(permutation) = scope.transformation.operation else {
            return 0
        }
        return permutation.swappableGroups.first?.count ?? 0
    }

    init<Output>(
        generator: Generator<Output>,
        value: Output,
        property: @escaping (Any) -> Bool
    ) throws {
        let tree = try #require(try Interpreters.reflect(generator, with: value))
        let graph = ChoiceGraph.build(from: tree)
        let permutation = try #require(PermutationQuery.build(graph: graph).first)
        scope = EncoderInput(
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
        state = SwapSessionState(
            sequence: ChoiceSequence(tree),
            tree: tree,
            output: value,
            graph: graph,
            gen: generator.erase(),
            property: property
        )
    }

    /// Runs one probe session for the sibling swap encoder, starting with its initial swap. Stops after 100 encode and decode steps, far more than any of these four-slot sessions need, and records whether the session finished on its own.
    mutating func run() throws -> PassReport {
        var encoder = ChoiceGraphScheduler.selectEncoder(for: scope.transformation.operation, gen: state.gen)
        encoder.start(scope: scope)
        var session = ProbeSession(
            encoder: encoder,
            transformation: scope.transformation,
            boundValueFingerprint: nil,
            baseSequence: state.sequence,
            hasBind: false
        )
        for _ in 0 ..< 100 where session.phase != .finished {
            _ = try session.step(state: &state)
        }
        sessionFinished = session.phase == .finished
        return session.report()
    }
}

private struct SwapSessionState: ProbeSessionState {
    var sequence: ChoiceSequence
    var tree: ChoiceTree
    var output: Any
    var graph: ChoiceGraph
    var gen: AnyGenerator
    let property: (Any) -> Bool
    let probeWrapper: ProbeWrapper? = nil
    var rejectCache: Set<UInt64> = []
    let collectStats = true
    let isInstrumented = false
}
