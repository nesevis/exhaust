//
//  GraphEncoderTests.swift
//  Exhaust
//

@testable import ExhaustCore
import Testing

// MARK: - Graph Encoder Tests

@Suite("GraphEncoders")
struct GraphEncoderTests {

    // MARK: - GraphDeletionEncoder

    @Test("Deletion encoder removes members of the deletion antichain")
    func deletionEncoderRemovesAntichainMembers() {
        // Three independent sequences under a zip — antichain has three deletable members.
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
        let sequence = ChoiceSequence.flatten(tree)
        let graph = ChoiceGraph.build(from: tree)

        var encoder = GraphDeletionEncoder()
        encoder.start(graph: graph, sequence: sequence, tree: tree)

        // Should produce at least one candidate that is shortlex-smaller.
        var candidates: [ChoiceSequence] = []
        var lastAccepted = false
        while let probe = encoder.nextProbe(lastAccepted: lastAccepted) {
            candidates.append(probe)
            lastAccepted = false
        }

        #expect(candidates.isEmpty == false)
        // All candidates should be shorter than the original.
        for candidate in candidates {
            #expect(candidate.count < sequence.count)
        }
    }

    // MARK: - GraphValueSearchEncoder

    @Test("Value search encoder drives non-zero leaves toward zero")
    func valueSearchDrivesLeafTowardZero() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(42, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(.unsigned(99, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let sequence = ChoiceSequence.flatten(tree)
        let graph = ChoiceGraph.build(from: tree)

        var encoder = GraphValueSearchEncoder()
        encoder.start(graph: graph, sequence: sequence, tree: tree)

        // First probe should be the batch-zero attempt (all simplest).
        let firstProbe = encoder.nextProbe(lastAccepted: false)
        #expect(firstProbe != nil)

        // The batch probe should contain zero values where the originals were non-zero.
        if let probe = firstProbe {
            let originalValues = sequence.compactMap({ $0.value?.choice.bitPattern64 })
            let probeValues = probe.compactMap({ $0.value?.choice.bitPattern64 })
            // At least one value should be zero (the semantic simplest for unsigned).
            #expect(probeValues.contains(0))
            #expect(probeValues != originalValues)
        }
    }

    @Test("Value search encoder emits convergence records")
    func valueSearchEmitsConvergenceRecords() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(50, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let sequence = ChoiceSequence.flatten(tree)
        let graph = ChoiceGraph.build(from: tree)

        var encoder = GraphValueSearchEncoder()
        encoder.start(graph: graph, sequence: sequence, tree: tree)

        // Exhaust all probes (simulate all rejections).
        while let _ = encoder.nextProbe(lastAccepted: false) {}

        // Should have produced convergence records.
        #expect(encoder.convergenceRecords.isEmpty == false)
    }

    // MARK: - GraphRedistributionEncoder

    @Test("Redistribution encoder produces candidates for type-compatible pairs")
    func redistributionProducesCandiatesForCompatiblePairs() {
        // Two uint64 leaves under a zip — type-compatible.
        let tree = ChoiceTree.group([
            .choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(.unsigned(5, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let sequence = ChoiceSequence.flatten(tree)
        let graph = ChoiceGraph.build(from: tree)

        var encoder = GraphRedistributionEncoder()
        encoder.start(graph: graph, sequence: sequence, tree: tree)

        var candidates: [ChoiceSequence] = []
        while let probe = encoder.nextProbe(lastAccepted: false) {
            candidates.append(probe)
        }

        // Should produce at least one redistribution probe (zero source, absorb into sink).
        #expect(candidates.isEmpty == false)
    }

    // MARK: - GraphBranchPivotEncoder

    @Test("Branch pivot encoder produces candidates for pick sites with alternatives")
    func branchPivotProducesCandidates() {
        // A pick site with two branches.
        let tree = ChoiceTree.group([
            .selected(.branch(
                siteID: 1000,
                weight: 1,
                id: 0,
                branchIDs: [0, 1],
                choice: .choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
            )),
            .branch(
                siteID: 1000,
                weight: 1,
                id: 1,
                branchIDs: [0, 1],
                choice: .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
            ),
        ])
        let sequence = ChoiceSequence.flatten(tree)
        let graph = ChoiceGraph.build(from: tree)

        var encoder = GraphBranchPivotEncoder()
        encoder.start(graph: graph, sequence: sequence, tree: tree)

        var candidates: [ChoiceSequence] = []
        while let probe = encoder.nextProbe(lastAccepted: false) {
            candidates.append(probe)
        }

        // Should produce at least one pivot candidate (swapping to the alternative branch).
        #expect(candidates.isEmpty == false)
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

        // Should reduce to the boundary value (5).
        #expect(result.1 == 5)
    }

    @Test("Bind-dependent array length shrinks correctly via graph reducer")
    func bindDependentReduction() throws {
        let gen = Gen.choose(in: 1 ... 10 as ClosedRange<Int>)._bound(
            forward: { length in
                Gen.arrayOf(Gen.choose(in: 0 ... 100 as ClosedRange<Int>), exactly: UInt64(length))
            },
            backward: { (array: [Int]) in
                array.count
            }
        )

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        var failingTree: ChoiceTree?
        var failingValue: [Int]?
        while let (value, tree) = try iterator.next() {
            if value.count > 2 {
                failingTree = tree
                failingValue = value
                break
            }
        }

        let tree = try #require(failingTree)
        let value = try #require(failingValue)

        let (_, shrunk) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, output: value, config: .fast) {
                $0.count <= 2
            }
        )
        print()

        // Minimum counterexample: a 3-element array with all zeros.
        #expect(shrunk.count == 3)
        #expect(shrunk.allSatisfy { $0 == 0 })
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
