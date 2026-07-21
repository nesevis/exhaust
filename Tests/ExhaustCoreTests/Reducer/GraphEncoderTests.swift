//
//  GraphEncoderTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

// MARK: - Graph Encoder Tests

@Suite("GraphEncoders")
struct GraphEncoderTests {
    // MARK: - GraphStructuralEncoder (Removal)

    @Test("Removal encoder removes members of the deletion antichain")
    func removalEncoderRemovesAntichainMembers() {
        let seq1 = ChoiceTree.sequence(
            elements: [
                .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            metadata: .init(validRange: nil, isRangeExplicit: false)
        )
        let seq2 = ChoiceTree.sequence(
            elements: [
                .choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            metadata: .init(validRange: nil, isRangeExplicit: false)
        )
        let seq3 = ChoiceTree.sequence(
            elements: [
                .choice(ChoiceValue(4 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            metadata: .init(validRange: nil, isRangeExplicit: false)
        )
        let tree = ChoiceTree.group([seq1, seq2, seq3])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = Self.removalScope(tree: tree, graph: graph) else {
            Issue.record("No removal scope found")
            return
        }

        var encoder = GraphStructuralEncoder()
        encoder.start(scope: scope)

        var candidates: [ChoiceSequence] = []
        var lastAccepted = false
        var candidateBuffer = sequence
        while encoder.nextProbe(into: &candidateBuffer, lastAccepted: lastAccepted) != nil {
            candidates.append(candidateBuffer)
            lastAccepted = false
        }

        #expect(candidates.isEmpty == false)
        for candidate in candidates {
            #expect(candidate.count < sequence.count)
        }
    }

    // MARK: - GraphValueEncoder

    @Test("Minimization encoder drives non-zero leaves toward zero")
    func minimizationDrivesLeafTowardZero() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(42 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(ChoiceValue(99 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)

        guard let scope = Self.minimizationScope(tree: tree, graph: graph) else {
            Issue.record("No minimization scope found")
            return
        }

        var encoder = GraphValueEncoder()
        encoder.start(scope: scope)

        var candidateBuffer = ChoiceSequence.flatten(tree)
        let firstProbe = encoder.nextProbe(into: &candidateBuffer, lastAccepted: false)
        #expect(firstProbe != nil)

        if firstProbe != nil {
            let probeValues = candidateBuffer.compactMap { $0.value?.choice.bitPattern64 }
            #expect(probeValues.contains(0))
        }
    }

    // MARK: - GraphStructuralEncoder (Migration)

    @Test("Migration encoder merges sibling sequences and removes the empty source")
    func migrationMergesSiblingSequencesAndShortens() throws {
        // Two sibling sequences under an outer sequence node — the sequence-of-sequences shape used by NestedLists and LargeUnionList.
        let inner1 = ChoiceTree.sequence(
            elements: [
                .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
                .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            ],
            metadata: .init(validRange: nil, isRangeExplicit: false)
        )
        let inner2 = ChoiceTree.sequence(
            elements: [
                .choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            ],
            metadata: .init(validRange: nil, isRangeExplicit: false)
        )
        let outer = ChoiceTree.sequence(
            elements: [inner1, inner2],
            metadata: .init(validRange: nil, isRangeExplicit: false)
        )
        let graph = ChoiceGraph.build(from: outer)
        let sequence = ChoiceSequence.flatten(outer)

        // Find inner1 and inner2 node IDs (the two sibling sequences).
        let sequenceNodes = graph.nodes.compactMap { node -> Int? in
            guard case .sequence = node.kind else { return nil }
            guard node.positionRange != nil else { return nil }
            return node.id
        }
        // Three sequences: outer, inner1, inner2.
        #expect(sequenceNodes.count == 3)

        // Sort by position to identify outer (first) → inner1 → inner2.
        let sortedSequenceNodes = sequenceNodes.sorted { lhs, rhs in
            let lhsRange = graph.nodes[lhs].positionRange?.lowerBound ?? 0
            let rhsRange = graph.nodes[rhs].positionRange?.lowerBound ?? 0
            return lhsRange < rhsRange
        }
        // outer is the smallest position; inner1 and inner2 follow.
        let inner1NodeID = sortedSequenceNodes[1]
        let inner2NodeID = sortedSequenceNodes[2]

        // Build a migration scope: move inner1 → inner2.
        guard case let .sequence(inner1Meta) = graph.nodes[inner1NodeID].kind else {
            Issue.record("inner1 should be a sequence")
            return
        }
        guard let inner2Range = graph.nodes[inner2NodeID].positionRange else {
            Issue.record("inner2 should have a position range")
            return
        }
        let migrationScope = MigrationScope(
            sourceSequenceNodeID: inner1NodeID,
            receiverSequenceNodeID: inner2NodeID,
            elementNodeIDs: graph.nodes[inner1NodeID].children,
            elementPositionRanges: inner1Meta.childPositionRanges,
            receiverPositionRange: inner2Range,
            sourceParentSequenceNodeID: nil
        )
        let transformation = GraphTransformation(
            operation: .migrate(migrationScope),
            priority: DispatchPriority(
                structuralBenefit: 1,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: 1
            )
        )
        let scope = EncoderInput(
            transformation: transformation,
            baseSequence: sequence,
            tree: outer,
            graph: graph,
            warmStartRecords: [:]
        )

        var encoder = GraphStructuralEncoder()
        encoder.start(scope: scope)
        var candidateBuffer = sequence
        let probe = encoder.nextProbe(into: &candidateBuffer, lastAccepted: false)
        try #require(probe != nil, "Migration encoder should produce at least one probe")

        // Migration must produce a strictly shorter sequence (the source's
        // wrappers are removed entirely, not just emptied).
        #expect(candidateBuffer.count < sequence.count)
        // And it must shortlex-precede the original.
        #expect(candidateBuffer.shortLexPrecedes(sequence))
    }

    @Test("Minimization encoder emits convergence records")
    func minimizationEmitsConvergenceRecords() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(50 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)

        guard let scope = Self.minimizationScope(tree: tree, graph: graph) else {
            Issue.record("No minimization scope found")
            return
        }

        var encoder = GraphValueEncoder()
        encoder.start(scope: scope)

        var candidateBuffer = ChoiceSequence.flatten(tree)
        while encoder.nextProbe(into: &candidateBuffer, lastAccepted: false) != nil {}

        #expect(encoder.convergenceRecords.isEmpty == false)
    }

    // MARK: - GraphLockstepEncoder

    @Test("Lockstep window plan clamps float distances beyond UInt64.max")
    func lockstepPlanClampsHugeFloatDistance() throws {
        // Two finite doubles whose distance to the reduction target exceeds UInt64.max. Building the plan used to trap in the UInt64 conversion instead of clamping.
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(1e300, tag: .double), .init(validRange: nil, isRangeExplicit: false)),
            .choice(ChoiceValue(1e300, tag: .double), .init(validRange: nil, isRangeExplicit: false)),
        ])
        var encoder = GraphLockstepEncoder()
        encoder.valueState.reset(sequence: ChoiceSequence.flatten(tree))

        let plan = try #require(encoder.makeLockstepWindowPlan(windowIndices: [1, 2]))
        #expect(plan.distance == UInt64.max)
        #expect(plan.usesFloatingSteps)
    }

    // MARK: - Helpers

    /// Builds a scope for a removal transformation from a tree.
    private static func removalScope(
        tree: ChoiceTree,
        graph: ChoiceGraph
    ) -> EncoderInput? {
        let sequence = ChoiceSequence.flatten(tree)
        let scopes = RemovalQuery.elementRemovalScopes(graph: graph)
        guard let firstScope = scopes.first else { return nil }
        let transformation = GraphTransformation(
            operation: .remove(.elements(firstScope)),
            priority: DispatchPriority(
                structuralBenefit: firstScope.maxBatch,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: firstScope.maxBatch
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

    /// Builds a scope for integer minimization from a tree.
    private static func minimizationScope(
        tree: ChoiceTree,
        graph: ChoiceGraph
    ) -> EncoderInput? {
        let sequence = ChoiceSequence.flatten(tree)
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
}

// MARK: - Integration Tests

@Suite("ChoiceGraphReducer")
struct ChoiceGraphReducerIntegrationTests {
    @Test("Non-bind generator reduces to expected counterexample")
    func nonBindReduction() throws {
        let gen = Gen.choose(in: UInt64(0) ... 1000)

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (value, tree) = try #require(try iterator.next())
        try #require(value > 5)

        let (_, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, output: value, config: .init(maxStalls: 2)) {
                $0 < 5
            }.counterexample
        )

        #expect(output == 5)
    }

    @Test("CollectingStats returns valid statistics")
    func collectingStatsReturnsStats() throws {
        let gen = Gen.choose(in: UInt64(0) ... 100)

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (value, tree) = try #require(try iterator.next())
        try #require(value > 10)

        let result = try Interpreters.choiceGraphReduceCollectingStats(
            gen: gen,
            tree: tree,
            output: value,
            config: .init(maxStalls: 2)
        ) { $0 < 10 }

        if case .reduced = result.outcome {
            // Reduction succeeded
        } else {
            Issue.record("Expected .reduced outcome")
        }
        #expect(result.stats.cycles > 0)
        #expect(result.stats.totalMaterializations > 0)
    }
}
