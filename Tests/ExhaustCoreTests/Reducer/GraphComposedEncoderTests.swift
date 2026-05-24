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

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var composed = GraphComposedEncoder(
            name: .composed,
            upstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamScope: scope,
            downstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamBudget: 100,
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

        #expect(probeCount > 5, "Composition of two binary-search encoders over 0...100 should emit more than 5 probes")
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

        let unlimitedProbes = drainProbes(
            scope: scope,
            sequence: sequence,
            upstreamBudget: 100
        )

        let limitedProbes = drainProbes(
            scope: scope,
            sequence: sequence,
            upstreamBudget: 1
        )

        #expect(limitedProbes < unlimitedProbes, "Budget=1 should emit fewer probes than budget=100")
        #expect(limitedProbes > 0, "Budget=1 should still emit at least one probe")
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
            upstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamScope: scope,
            downstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamBudget: 2,
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

        #expect(liftCallCount > 2, "Failed lifts should cause additional upstream pulls beyond the budget count")
        #expect(probeCount > 0, "Should still emit probes from successful lifts")
    }

    // MARK: - Mutation Wrapping

    @Test("Composition wraps downstream mutation with mayReshape true")
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

        var composed = GraphComposedEncoder(
            name: .composed,
            upstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamScope: scope,
            downstream: .binarySearch(GraphBinarySearchEncoder()),
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
        #expect(changes.isEmpty == false)
        let allReshape = changes.allSatisfy(\.mayReshape)
        #expect(allReshape, "Composed mutations should have mayReshape set to true")
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
            upstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamScope: scope,
            downstream: .binarySearch(GraphBinarySearchEncoder()),
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
        #expect(afterRefresh == nil, "No probes should be emitted after refreshState")
    }

    // MARK: - Convergence Records

    @Test("Composition exposes upstream convergence records")
    func upstreamConvergenceExposed() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(10 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var composed = GraphComposedEncoder(
            name: .composed,
            upstream: .value(GraphValueEncoder()),
            upstreamScope: scope,
            downstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamBudget: 100,
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
        var accepted = false
        while composed.nextProbe(into: &buffer, lastAccepted: accepted) != nil {
            accepted = true
        }
        composed.flushPartialConvergence()

        let records = composed.convergenceRecords
        #expect(records.isEmpty == false, "Upstream value encoder should produce convergence records")
    }
}

// MARK: - Helpers

private func drainProbes(
    scope: EncoderInput,
    sequence: ChoiceSequence,
    upstreamBudget: Int
) -> Int {
    var composed = GraphComposedEncoder(
        name: .composed,
        upstream: .binarySearch(GraphBinarySearchEncoder()),
        upstreamScope: scope,
        downstream: .binarySearch(GraphBinarySearchEncoder()),
        upstreamBudget: upstreamBudget,
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
    var count = 0
    var buffer = sequence
    while composed.nextProbe(into: &buffer, lastAccepted: false) != nil {
        count += 1
    }
    return count
}

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
