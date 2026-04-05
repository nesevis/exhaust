//
//  GraphEncoderTests.swift
//  Exhaust
//

@testable import ExhaustCore
import Testing

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
        let scopes = graph.perParentRemovalScopes()
        guard let firstScope = scopes.first else { return nil }
        let transformation = GraphTransformation(
            operation: .remove(.perParent(firstScope)),
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
        let scopes = graph.minimizationScopes()
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

    // MARK: - GraphRemovalEncoder

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

        var encoder = GraphRemovalEncoder()
        encoder.start(scope: scope)

        var candidates: [ChoiceSequence] = []
        var lastAccepted = false
        while let probe = encoder.nextProbe(lastAccepted: lastAccepted) {
            candidates.append(probe)
            lastAccepted = false
        }

        #expect(candidates.isEmpty == false)
        for candidate in candidates {
            #expect(candidate.count < sequence.count)
        }
    }

    // MARK: - GraphMinimizationEncoder

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

        var encoder = GraphMinimizationEncoder()
        encoder.start(scope: scope)

        let firstProbe = encoder.nextProbe(lastAccepted: false)
        #expect(firstProbe != nil)

        if let probe = firstProbe {
            let probeValues = probe.compactMap { $0.value?.choice.bitPattern64 }
            #expect(probeValues.contains(0))
        }
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

        var encoder = GraphMinimizationEncoder()
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
