//
//  GraphEncoderTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

// MARK: - Graph Encoder Tests

@Suite("GraphEncoders")
struct GraphEncoderTests {
    // MARK: - Helpers

    /// Builds a scope for a removal transformation from a tree.
    private static func removalScope(
        tree: ChoiceTree,
        graph: ChoiceGraph
    ) -> TransformationScope? {
        let sequence = ChoiceSequence.flatten(tree)
        let scopes = RemovalScopeQuery.elementRemovalScopes(graph: graph)
        guard let firstScope = scopes.first else { return nil }
        let transformation = GraphTransformation(
            operation: .remove(.elements(firstScope)),
            yield: TransformationYield(
                structural: firstScope.maxBatch,
                value: 0,
                slack: .exact,
                estimatedProbes: firstScope.maxBatch
            ),
            precondition: .unconditional,
            postcondition: TransformationPostcondition(
                isStructural: true,
                invalidatesConvergence: [],
                enablesRemoval: []
            )
        )
        return TransformationScope(
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
    ) -> TransformationScope? {
        let sequence = ChoiceSequence.flatten(tree)
        let scopes = MinimizationScopeQuery.build(graph: graph)
        guard let firstScope = scopes.first else { return nil }
        let transformation = GraphTransformation(
            operation: .minimize(firstScope),
            yield: TransformationYield(
                structural: 0,
                value: 0,
                slack: .exact,
                estimatedProbes: 10
            ),
            precondition: .unconditional,
            postcondition: TransformationPostcondition(
                isStructural: false,
                invalidatesConvergence: [],
                enablesRemoval: []
            )
        )
        return TransformationScope(
            transformation: transformation,
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        )
    }

    // MARK: - GraphStructuralEncoder (Removal)

    @Test("Removal encoder removes members of the deletion antichain")
    func removalEncoderRemovesAntichainMembers() {
        let seq1 = ChoiceTree.sequence(
            length: 2,
            elements: [
                .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let seq2 = ChoiceTree.sequence(
            length: 1,
            elements: [
                .choice(.unsigned(3, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let seq3 = ChoiceTree.sequence(
            length: 1,
            elements: [
                .choice(.unsigned(4, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
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
        while let probe = encoder.nextProbe(lastAccepted: lastAccepted) {
            candidates.append(probe.candidate)
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
            .choice(.unsigned(42, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(.unsigned(99, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)

        guard let scope = Self.minimizationScope(tree: tree, graph: graph) else {
            Issue.record("No minimization scope found")
            return
        }

        var encoder = GraphValueEncoder()
        encoder.start(scope: scope)

        let firstProbe = encoder.nextProbe(lastAccepted: false)
        #expect(firstProbe != nil)

        if let probe = firstProbe {
            let probeValues = probe.candidate.compactMap { $0.value?.choice.bitPattern64 }
            #expect(probeValues.contains(0))
        }
    }

    // MARK: - GraphStructuralEncoder (Migration)

    @Test("Migration encoder merges sibling sequences and removes the empty source")
    func migrationMergesSiblingSequencesAndShortens() {
        // Two sibling sequences under an outer sequence node — the sequence-of-sequences shape used by NestedLists and LargeUnionList.
        let inner1 = ChoiceTree.sequence(
            length: 2,
            elements: [
                .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
                .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let inner2 = ChoiceTree.sequence(
            length: 1,
            elements: [
                .choice(.unsigned(3, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let outer = ChoiceTree.sequence(
            length: 2,
            elements: [inner1, inner2],
            .init(validRange: nil, isRangeExplicit: false)
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
            receiverPositionRange: inner2Range
        )
        let transformation = GraphTransformation(
            operation: .migrate(migrationScope),
            yield: TransformationYield(
                structural: 1,
                value: 0,
                slack: .exact,
                estimatedProbes: 1
            ),
            precondition: .unconditional,
            postcondition: TransformationPostcondition(
                isStructural: true,
                invalidatesConvergence: [],
                enablesRemoval: []
            )
        )
        let scope = TransformationScope(
            transformation: transformation,
            baseSequence: sequence,
            tree: outer,
            graph: graph,
            warmStartRecords: [:]
        )

        var encoder = GraphStructuralEncoder()
        encoder.start(scope: scope)
        let probe = encoder.nextProbe(lastAccepted: false)

        let resolvedProbe = try? #require(probe)
        guard let resolvedProbe else { return }
        let resolvedCandidate = resolvedProbe.candidate

        // Migration must produce a strictly shorter sequence (the source's
        // wrappers are removed entirely, not just emptied).
        #expect(resolvedCandidate.count < sequence.count)
        // And it must shortlex-precede the original.
        #expect(resolvedCandidate.shortLexPrecedes(sequence))
    }

    @Test("Minimization encoder emits convergence records")
    func minimizationEmitsConvergenceRecords() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(50, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)

        guard let scope = Self.minimizationScope(tree: tree, graph: graph) else {
            Issue.record("No minimization scope found")
            return
        }

        var encoder = GraphValueEncoder()
        encoder.start(scope: scope)

        while let _ = encoder.nextProbe(lastAccepted: false) {}

        #expect(encoder.convergenceRecords.isEmpty == false)
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

        let result = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, output: value, config: .fast) {
                $0 < 5
            }
        )

        #expect(result.1 == 5)
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
            config: .fast
        ) { $0 < 10 }

        #expect(result.reduced != nil)
        #expect(result.stats.cycles > 0)
        #expect(result.stats.totalMaterializations > 0)
    }
}
