import Testing
@testable import ExhaustCore

@Suite("DispatchDecision")
struct DispatchDecisionTests {
    private static let tuning = SchedulerTuning()

    // MARK: - Fixtures

    private nonisolated(unsafe) static let sequenceTree = ChoiceTree.sequence(
        length: 2,
        elements: [
            .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
        ],
        .init(validRange: nil, isRangeExplicit: false)
    )

    private nonisolated(unsafe) static let fixtureGraph = ChoiceGraph.build(from: sequenceTree)
    private nonisolated(unsafe) static let fixtureSequence = ChoiceSequence.flatten(sequenceTree)

    private static let defaultPriority = DispatchPriority(
        structuralBenefit: 1,
        valueBenefit: 0,
        reductionMagnitude: 0,
        estimatedCost: 1
    )

    // MARK: - Invalid Operations

    @Test("Invalid operation returns skip")
    func invalidOperationSkipped() {
        let transformation = GraphTransformation(
            operation: .remove(.subtree(nodeID: 9999, yield: 1)),
            priority: Self.defaultPriority
        )
        let decision = ChoiceGraphScheduler.evaluateDispatch(
            transformation: transformation,
            graph: Self.fixtureGraph,
            sequence: Self.fixtureSequence,
            gate: BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget),
            scopeCache: CandidateRejectionCache(),
            graphIsStripped: false,
            anyAccepted: false
        )
        #expect(decision == .skip)
    }

    // MARK: - Scope Rejection Cache

    @Test("Scope-rejected operation returns skip")
    func scopeRejectedSkipped() throws {
        let scopes = RemovalQuery.elementRemovalScopes(graph: Self.fixtureGraph)
        let scope = try #require(scopes.first, "Expected at least one removal scope")
        let operation = GraphOperation.remove(.elements(scope))
        let transformation = GraphTransformation(operation: operation, priority: Self.defaultPriority)

        var cache = CandidateRejectionCache()
        cache.recordRejection(
            operation: operation,
            sequence: Self.fixtureSequence,
            graph: Self.fixtureGraph
        )

        let decision = ChoiceGraphScheduler.evaluateDispatch(
            transformation: transformation,
            graph: Self.fixtureGraph,
            sequence: Self.fixtureSequence,
            gate: BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget),
            scopeCache: cache,
            graphIsStripped: false,
            anyAccepted: false
        )
        #expect(decision == .skip)
    }

    // MARK: - Non-Bound Value Operations

    @Test("Valid removal operation is ready to dispatch")
    func validRemovalDispatches() throws {
        let scopes = RemovalQuery.elementRemovalScopes(graph: Self.fixtureGraph)
        let scope = try #require(scopes.first, "Expected at least one removal scope")
        let operation = GraphOperation.remove(.elements(scope))
        let transformation = GraphTransformation(operation: operation, priority: Self.defaultPriority)

        let decision = ChoiceGraphScheduler.evaluateDispatch(
            transformation: transformation,
            graph: Self.fixtureGraph,
            sequence: Self.fixtureSequence,
            gate: BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget),
            scopeCache: CandidateRejectionCache(),
            graphIsStripped: false,
            anyAccepted: false
        )
        #expect(decision == .readyToDispatch(boundValueFingerprint: nil))
    }

    @Test("Valid minimization is ready to dispatch with nil fingerprint")
    func validMinimizationDispatches() throws {
        let scopes = MinimizationQuery.build(graph: Self.fixtureGraph)
        let scope = try #require(scopes.first, "Expected at least one minimization scope")
        let transformation = GraphTransformation(
            operation: .minimize(scope),
            priority: Self.defaultPriority
        )

        let decision = ChoiceGraphScheduler.evaluateDispatch(
            transformation: transformation,
            graph: Self.fixtureGraph,
            sequence: Self.fixtureSequence,
            gate: BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget),
            scopeCache: CandidateRejectionCache(),
            graphIsStripped: false,
            anyAccepted: false
        )
        #expect(decision == .readyToDispatch(boundValueFingerprint: nil))
    }

    // MARK: - Graph Stripped + Path-Changing

    @Test("Path-changing operation on stripped graph returns rematerialize")
    func strippedGraphRematerializes() {
        let transformation = GraphTransformation(
            operation: .replace(.branchPivot(pickNodeID: 0, targetBranchID: 1)),
            priority: Self.defaultPriority
        )
        let decision = ChoiceGraphScheduler.evaluateDispatch(
            transformation: transformation,
            graph: Self.fixtureGraph,
            sequence: Self.fixtureSequence,
            gate: BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget),
            scopeCache: CandidateRejectionCache(),
            graphIsStripped: true,
            anyAccepted: false
        )
        #expect(decision == .rematerialize)
    }

    @Test("Non-path-changing operation on stripped graph dispatches normally")
    func strippedGraphNonPathChanging() throws {
        let scopes = RemovalQuery.elementRemovalScopes(graph: Self.fixtureGraph)
        let scope = try #require(scopes.first, "Expected at least one removal scope")
        let transformation = GraphTransformation(
            operation: .remove(.elements(scope)),
            priority: Self.defaultPriority
        )

        let decision = ChoiceGraphScheduler.evaluateDispatch(
            transformation: transformation,
            graph: Self.fixtureGraph,
            sequence: Self.fixtureSequence,
            gate: BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget),
            scopeCache: CandidateRejectionCache(),
            graphIsStripped: true,
            anyAccepted: false
        )
        #expect(decision == .readyToDispatch(boundValueFingerprint: nil))
    }

    // MARK: - Bound Value Gate Integration

    @Test("Bound value with fruitless gate returns skip")
    func boundValueFruitlessSkipped() throws {
        let bindTree = ChoiceTree.bind(
            fingerprint: 0xABCD,
            inner: .choice(ChoiceValue(5 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            bound: .choice(ChoiceValue(10 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        )
        let graph = ChoiceGraph.build(from: bindTree)
        let sequence = ChoiceSequence.flatten(bindTree)

        let bindID = try #require(
            graph.nodes.firstIndex { node in
                if case .bind = node.kind { return true }
                return false
            },
            "Expected bind node in graph"
        )
        guard case let .bind(metadata) = graph.nodes[bindID].kind else {
            Issue.record("Expected bind kind at node \(bindID)")
            return
        }

        let innerChildID = graph.nodes[bindID].children[metadata.innerChildIndex]
        let boundChildID = graph.nodes[bindID].children[metadata.boundChildIndex]

        let scope = BoundValueScope(
            bindNodeID: bindID,
            upstreamLeafNodeID: innerChildID,
            downstreamNodeIDs: [boundChildID],
            boundSubtreeSize: 1
        )
        let transformation = GraphTransformation(
            operation: .minimize(.boundValue(scope)),
            priority: Self.defaultPriority
        )

        var gate = BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget)
        gate.markFruitless(metadata.fingerprint)

        let decision = ChoiceGraphScheduler.evaluateDispatch(
            transformation: transformation,
            graph: graph,
            sequence: sequence,
            gate: gate,
            scopeCache: CandidateRejectionCache(),
            graphIsStripped: false,
            anyAccepted: false
        )
        #expect(decision == .skip)
    }

    @Test("Bound value with acceptance deferral returns skip")
    func boundValueAcceptanceDeferralSkipped() throws {
        let bindTree = ChoiceTree.bind(
            fingerprint: 0xABCD,
            inner: .choice(ChoiceValue(5 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            bound: .choice(ChoiceValue(10 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        )
        let graph = ChoiceGraph.build(from: bindTree)
        let sequence = ChoiceSequence.flatten(bindTree)

        let bindID = try #require(
            graph.nodes.firstIndex { node in
                if case .bind = node.kind { return true }
                return false
            },
            "Expected bind node in graph"
        )
        guard case let .bind(metadata) = graph.nodes[bindID].kind else {
            Issue.record("Expected bind kind at node \(bindID)")
            return
        }

        let innerChildID = graph.nodes[bindID].children[metadata.innerChildIndex]
        let boundChildID = graph.nodes[bindID].children[metadata.boundChildIndex]

        let scope = BoundValueScope(
            bindNodeID: bindID,
            upstreamLeafNodeID: innerChildID,
            downstreamNodeIDs: [boundChildID],
            boundSubtreeSize: 1
        )
        let transformation = GraphTransformation(
            operation: .minimize(.boundValue(scope)),
            priority: Self.defaultPriority
        )

        let decision = ChoiceGraphScheduler.evaluateDispatch(
            transformation: transformation,
            graph: graph,
            sequence: sequence,
            gate: BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget),
            scopeCache: CandidateRejectionCache(),
            graphIsStripped: false,
            anyAccepted: true
        )
        #expect(decision == .skip)
    }

    @Test("Bound value needing classification returns classifyBind")
    func boundValueNeedsClassification() throws {
        let bindTree = ChoiceTree.bind(
            fingerprint: 0xABCD,
            inner: .choice(ChoiceValue(5 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            bound: .choice(ChoiceValue(10 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        )
        let graph = ChoiceGraph.build(from: bindTree)
        let sequence = ChoiceSequence.flatten(bindTree)

        let bindID = try #require(
            graph.nodes.firstIndex { node in
                if case .bind = node.kind { return true }
                return false
            },
            "Expected bind node in graph"
        )
        guard case let .bind(metadata) = graph.nodes[bindID].kind else {
            Issue.record("Expected bind kind at node \(bindID)")
            return
        }

        let innerChildID = graph.nodes[bindID].children[metadata.innerChildIndex]
        let boundChildID = graph.nodes[bindID].children[metadata.boundChildIndex]

        let scope = BoundValueScope(
            bindNodeID: bindID,
            upstreamLeafNodeID: innerChildID,
            downstreamNodeIDs: [boundChildID],
            boundSubtreeSize: 1
        )
        let transformation = GraphTransformation(
            operation: .minimize(.boundValue(scope)),
            priority: Self.defaultPriority
        )

        let decision = ChoiceGraphScheduler.evaluateDispatch(
            transformation: transformation,
            graph: graph,
            sequence: sequence,
            gate: BoundValueGate(baseBudget: Self.tuning.boundValueBaseBudget),
            scopeCache: CandidateRejectionCache(),
            graphIsStripped: false,
            anyAccepted: false
        )
        #expect(decision == .classifyBind(bindNodeID: bindID, fingerprint: metadata.fingerprint))
    }
}
