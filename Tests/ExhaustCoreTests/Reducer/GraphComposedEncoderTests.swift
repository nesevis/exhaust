import Testing
@testable import ExhaustCore

@Suite("GraphComposedEncoder")
struct GraphComposedEncoderTests {
    // MARK: - Upstream × Downstream Iteration

    @Test("Composition emits downstream probes for each upstream probe")
    func downstreamPerUpstream() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(10 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let upstreamScope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        let upstream = StubEncoder(probeCount: 3)
        let downstream = StubEncoder(probeCount: 2)

        var composed = GraphComposedEncoder(
            name: .composed,
            upstream: upstream,
            upstreamScope: upstreamScope,
            downstream: downstream,
            upstreamBudget: 10,
            lift: { candidate, _, parent in
                EncoderInput(
                    transformation: parent.transformation,
                    baseSequence: candidate,
                    tree: parent.tree,
                    graph: parent.graph,
                    warmStartRecords: [:]
                )
            }
        )

        composed.start(scope: upstreamScope)
        var probeCount = 0
        var buffer = sequence
        while composed.nextProbe(into: &buffer, lastAccepted: false) != nil {
            probeCount += 1
        }

        #expect(probeCount == 6)
    }

    // MARK: - Budget Enforcement

    @Test("Composition stops pulling upstream after budget is exhausted")
    func budgetEnforcement() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(50 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var composed = GraphComposedEncoder(
            name: .composed,
            upstream: StubEncoder(probeCount: 10),
            upstreamScope: scope,
            downstream: StubEncoder(probeCount: 1),
            upstreamBudget: 3,
            lift: { candidate, _, parent in
                EncoderInput(
                    transformation: parent.transformation,
                    baseSequence: candidate,
                    tree: parent.tree,
                    graph: parent.graph,
                    warmStartRecords: [:]
                )
            }
        )

        composed.start(scope: scope)
        var probeCount = 0
        var buffer = sequence
        while composed.nextProbe(into: &buffer, lastAccepted: false) != nil {
            probeCount += 1
        }

        #expect(probeCount == 3)
    }

    // MARK: - Lift Failure

    @Test("Failed lifts are skipped without counting against budget")
    func liftFailureSkipped() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(20 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var liftCallCount = 0
        var composed = GraphComposedEncoder(
            name: .composed,
            upstream: StubEncoder(probeCount: 6),
            upstreamScope: scope,
            downstream: StubEncoder(probeCount: 1),
            upstreamBudget: 3,
            lift: { candidate, _, parent in
                liftCallCount += 1
                if liftCallCount % 2 == 0 { return nil }
                return EncoderInput(
                    transformation: parent.transformation,
                    baseSequence: candidate,
                    tree: parent.tree,
                    graph: parent.graph,
                    warmStartRecords: [:]
                )
            }
        )

        composed.start(scope: scope)
        var probeCount = 0
        var buffer = sequence
        while composed.nextProbe(into: &buffer, lastAccepted: false) != nil {
            probeCount += 1
        }

        #expect(probeCount == 3)
        #expect(liftCallCount == 5)
    }

    // MARK: - Mutation Wrapping

    @Test("Composition wraps downstream mutation with upstream's leaf changes and mayReshape true")
    func mutationWrapping() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(30 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        let upstreamLeafChange = LeafChange(leafNodeID: 0, newValue: ChoiceValue(15 as UInt64, tag: .uint64), mayReshape: false)
        var composed = GraphComposedEncoder(
            name: .composed,
            upstream: StubEncoder(probeCount: 1, leafChanges: [upstreamLeafChange]),
            upstreamScope: scope,
            downstream: StubEncoder(probeCount: 1),
            upstreamBudget: 5,
            lift: { candidate, _, parent in
                EncoderInput(
                    transformation: parent.transformation,
                    baseSequence: candidate,
                    tree: parent.tree,
                    graph: parent.graph,
                    warmStartRecords: [:]
                )
            }
        )

        composed.start(scope: scope)
        var buffer = sequence
        guard let mutation = composed.nextProbe(into: &buffer, lastAccepted: false) else {
            Issue.record("Expected at least one probe")
            return
        }

        guard case let .leafValues(changes) = mutation else {
            Issue.record("Expected leafValues mutation, got \(mutation)")
            return
        }
        #expect(changes.count == 1)
        #expect(changes[0].leafNodeID == 0)
        #expect(changes[0].mayReshape == true)
    }

    // MARK: - refreshState Aborts In-Flight

    @Test("refreshState resets composition so no further probes are emitted")
    func refreshStateResetsComposition() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(40 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var composed = GraphComposedEncoder(
            name: .composed,
            upstream: StubEncoder(probeCount: 5),
            upstreamScope: scope,
            downstream: StubEncoder(probeCount: 3),
            upstreamBudget: 10,
            lift: { candidate, _, parent in
                EncoderInput(
                    transformation: parent.transformation,
                    baseSequence: candidate,
                    tree: parent.tree,
                    graph: parent.graph,
                    warmStartRecords: [:]
                )
            }
        )

        composed.start(scope: scope)
        var buffer = sequence
        _ = composed.nextProbe(into: &buffer, lastAccepted: false)

        composed.refreshState(graph: graph, sequence: sequence)
        let afterRefresh = composed.nextProbe(into: &buffer, lastAccepted: false)
        #expect(afterRefresh == nil)
    }

    // MARK: - Zero Upstream Probes

    @Test("Composition with zero upstream probes emits nothing")
    func zeroUpstreamProbes() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(5 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var composed = GraphComposedEncoder(
            name: .composed,
            upstream: StubEncoder(probeCount: 0),
            upstreamScope: scope,
            downstream: StubEncoder(probeCount: 5),
            upstreamBudget: 10,
            lift: { _, _, _ in nil }
        )

        composed.start(scope: scope)
        var buffer = sequence
        let probe = composed.nextProbe(into: &buffer, lastAccepted: false)
        #expect(probe == nil)
    }

    // MARK: - Zero Downstream Probes

    @Test("Upstream probe with zero downstream probes advances to next upstream")
    func zeroDownstreamAdvances() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(25 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var liftCount = 0
        var composed = GraphComposedEncoder(
            name: .composed,
            upstream: StubEncoder(probeCount: 3),
            upstreamScope: scope,
            downstream: AlternatingDownstream(),
            upstreamBudget: 10,
            lift: { candidate, _, parent in
                liftCount += 1
                return EncoderInput(
                    transformation: parent.transformation,
                    baseSequence: candidate,
                    tree: parent.tree,
                    graph: parent.graph,
                    warmStartRecords: [:]
                )
            }
        )

        composed.start(scope: scope)
        var probeCount = 0
        var buffer = sequence
        while composed.nextProbe(into: &buffer, lastAccepted: false) != nil {
            probeCount += 1
        }

        #expect(liftCount == 3)
        #expect(probeCount == 2)
    }

    // MARK: - Convergence Records

    @Test("Composition exposes upstream convergence records only")
    func upstreamConvergenceOnly() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(10 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        let composed = GraphComposedEncoder(
            name: .composed,
            upstream: StubEncoder(probeCount: 0, convergence: [42: ConvergedOrigin(bound: 5, signal: .monotoneConvergence, configuration: .binarySearchSemanticSimplest, cycle: 0)]),
            upstreamScope: scope,
            downstream: StubEncoder(probeCount: 0, convergence: [99: ConvergedOrigin(bound: 1, signal: .monotoneConvergence, configuration: .binarySearchSemanticSimplest, cycle: 0)]),
            upstreamBudget: 10,
            lift: { _, _, _ in nil }
        )

        let records = composed.convergenceRecords
        #expect(records[42] != nil)
        #expect(records[99] == nil)
    }
}

// MARK: - Stub Encoder

private struct StubEncoder: GraphEncoder {
    let name: EncoderName = .valueSearch
    let probeCount: Int
    var leafChanges: [LeafChange]
    var convergence: [Int: ConvergedOrigin]
    private var remaining: Int = 0
    private var baseSequence: ChoiceSequence = .init([])

    init(probeCount: Int, leafChanges: [LeafChange] = [], convergence: [Int: ConvergedOrigin] = [:]) {
        self.probeCount = probeCount
        self.leafChanges = leafChanges
        self.convergence = convergence
        remaining = probeCount
    }

    var convergenceRecords: [Int: ConvergedOrigin] {
        convergence
    }

    mutating func start(scope: EncoderInput) {
        remaining = probeCount
        baseSequence = scope.baseSequence
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted _: Bool) -> EncoderProbe? {
        guard remaining > 0 else { return nil }
        remaining -= 1
        candidate = baseSequence
        if leafChanges.isEmpty {
            return .leafValues([LeafChange(leafNodeID: 0, newValue: ChoiceValue(0 as UInt64, tag: .uint64), mayReshape: false)])
        }
        return .leafValues(leafChanges)
    }
}

private struct AlternatingDownstream: GraphEncoder {
    let name: EncoderName = .boundValueSearch
    private var startCount = 0
    private var emitted = false
    private var baseSequence: ChoiceSequence = .init([])

    mutating func start(scope: EncoderInput) {
        startCount += 1
        emitted = false
        baseSequence = scope.baseSequence
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted _: Bool) -> EncoderProbe? {
        guard emitted == false, startCount % 2 == 1 else { return nil }
        emitted = true
        candidate = baseSequence
        return .leafValues([])
    }
}

// MARK: - Helpers

private func minimizationScope(
    tree: ChoiceTree,
    graph: ChoiceGraph,
    sequence: ChoiceSequence
) -> EncoderInput? {
    let scopes = MinimizationQuery.build(graph: graph)
    guard let firstScope = scopes.first else { return nil }
    let transformation = GraphTransformation(
        operation: .minimize(firstScope),
        priority: DispatchPriority(
            structuralBenefit: 0,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 10
        )
    )
    return EncoderInput(
        transformation: transformation,
        baseSequence: sequence,
        tree: tree,
        graph: graph,
        warmStartRecords: [:]
    )
}
