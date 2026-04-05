//
//  ChoiceGraphScopeQueryTests.swift
//  Exhaust
//

@testable import ExhaustCore
import Testing

// MARK: - Scope Query Tests

@Suite("ChoiceGraph Scope Queries")
struct ChoiceGraphScopeQueryTests {

    // MARK: - Aligned Removal

    @Test("Aligned removal scope for zip of two sequences")
    func alignedRemovalTwoSequences() {
        let seq1 = ChoiceTree.sequence(
            length: 3,
            elements: [
                .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(.unsigned(3, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let seq2 = ChoiceTree.sequence(
            length: 2,
            elements: [
                .choice(.unsigned(4, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(.unsigned(5, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let tree = ChoiceTree.group([seq1, seq2])
        let graph = ChoiceGraph.build(from: tree)
        let scopes = graph.alignedRemovalScopes()

        #expect(scopes.count == 1)
        #expect(scopes[0].siblings.count == 2)
        #expect(scopes[0].maxAlignedWindow == 2)
        #expect(scopes[0].maxYield > 0)
    }

    @Test("No aligned removal for zip of non-sequence children")
    func noAlignedRemovalForLeaves() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let scopes = graph.alignedRemovalScopes()

        #expect(scopes.isEmpty)
    }

    // MARK: - Per-Parent Removal

    @Test("Per-parent removal for simple sequence")
    func perParentRemovalSimple() {
        let tree = ChoiceTree.sequence(
            length: 3,
            elements: [
                .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(.unsigned(3, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let graph = ChoiceGraph.build(from: tree)
        let scopes = graph.perParentRemovalScopes()

        #expect(scopes.count == 1)
        #expect(scopes[0].elementNodeIDs.count == 3)
        #expect(scopes[0].maxBatch == 3)
    }

    @Test("Per-parent removal respects length constraint")
    func perParentRemovalConstrained() {
        let tree = ChoiceTree.sequence(
            length: 3,
            elements: [
                .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(.unsigned(3, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: 2 ... 5, isRangeExplicit: true)
        )
        let graph = ChoiceGraph.build(from: tree)
        let scopes = graph.perParentRemovalScopes()

        #expect(scopes.count == 1)
        #expect(scopes[0].maxBatch == 1)
    }

    // MARK: - Minimisation

    @Test("Integer minimisation scope collects non-zero leaves")
    func integerMinimisationScope() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(42, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(.unsigned(99, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let scopes = graph.minimisationScopes()

        let integerScopes = scopes.filter {
            if case .integerLeaves = $0 { return true }
            return false
        }
        #expect(integerScopes.count == 1)
        if case let .integerLeaves(scope) = integerScopes.first {
            #expect(scope.leafNodeIDs.count == 2)
            #expect(scope.batchZeroEligible)
        }
    }

    @Test("Minimisation scope excludes already-converged leaves")
    func minimisationSkipsConverged() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(0, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(.unsigned(0, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let scopes = graph.minimisationScopes()

        // Both leaves are at their reduction target (0) — no minimisation scope.
        let integerScopes = scopes.filter {
            if case .integerLeaves = $0 { return true }
            return false
        }
        #expect(integerScopes.isEmpty)
    }

    // MARK: - Permutation

    @Test("Permutation scope for zip with same-shaped siblings")
    func permutationSameShape() {
        let seq1 = ChoiceTree.sequence(
            length: 1,
            elements: [
                .choice(.unsigned(5, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
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
        let tree = ChoiceTree.group([seq1, seq2])
        let graph = ChoiceGraph.build(from: tree)
        let scopes = graph.permutationScopes()

        #expect(scopes.count == 1)
        if case let .siblingPermutation(scope) = scopes.first {
            #expect(scope.swappableGroups.count == 1)
            #expect(scope.swappableGroups[0].count == 2)
        }
    }

    // MARK: - Enumerator Integration

    // MARK: - Aligned Removal Encoder

    @Test("Aligned removal encoder produces candidates removing from all siblings")
    func alignedRemovalProducesCandidates() {
        let seq1 = ChoiceTree.sequence(
            length: 3,
            elements: [
                .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
                .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
                .choice(.unsigned(3, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let seq2 = ChoiceTree.sequence(
            length: 2,
            elements: [
                .choice(.unsigned(4, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
                .choice(.unsigned(5, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let tree = ChoiceTree.group([seq1, seq2])
        let sequence = ChoiceSequence.flatten(tree)
        let graph = ChoiceGraph.build(from: tree)

        let alignedScopes = graph.alignedRemovalScopes()
        guard let alignedScope = alignedScopes.first else {
            Issue.record("No aligned removal scope found")
            return
        }

        let transformation = GraphTransformation(
            operation: .removal(.aligned(alignedScope)),
            yield: TransformationYield(
                structural: alignedScope.maxYield,
                value: 0,
                slack: .exact,
                estimatedProbes: 4
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
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        )

        var encoder = GraphRemovalEncoder()
        encoder.start(scope: scope)

        var candidates: [ChoiceSequence] = []
        var lastAccepted = false
        while let probe = encoder.nextProbe(lastAccepted: lastAccepted) {
            candidates.append(probe)
            lastAccepted = false
        }

        #expect(candidates.isEmpty == false)
        // Aligned removal removes from BOTH sequences simultaneously,
        // so candidates should be shorter by at least 2 (one element per sibling).
        for candidate in candidates {
            #expect(candidate.count < sequence.count)
            // At least 2 positions removed (one from each sibling).
            #expect(sequence.count - candidate.count >= 2)
        }
    }

    // MARK: - Enumerator

    @Test("Enumerator produces sorted transformations")
    func enumeratorSorted() {
        let seq1 = ChoiceTree.sequence(
            length: 3,
            elements: [
                .choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
                .choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
                .choice(.unsigned(30, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let seq2 = ChoiceTree.sequence(
            length: 2,
            elements: [
                .choice(.unsigned(40, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
                .choice(.unsigned(50, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let tree = ChoiceTree.group([seq1, seq2])
        let graph = ChoiceGraph.build(from: tree)
        let transformations = TransformationEnumerator.enumerate(from: graph)

        #expect(transformations.isEmpty == false)

        // Verify sorted: each element should be <= the next (higher or equal priority).
        for index in 0 ..< transformations.count - 1 {
            let current = transformations[index].yield
            let next = transformations[index + 1].yield
            // current should be higher or equal priority (less than or equal in sort order).
            #expect(current <= next || current == next)
        }
    }

    @Test("Enumerator includes aligned removal for zip of sequences")
    func enumeratorIncludesAligned() {
        let seq1 = ChoiceTree.sequence(
            length: 2,
            elements: [
                .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let seq2 = ChoiceTree.sequence(
            length: 2,
            elements: [
                .choice(.unsigned(3, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(.unsigned(4, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let tree = ChoiceTree.group([seq1, seq2])
        let graph = ChoiceGraph.build(from: tree)
        let transformations = TransformationEnumerator.enumerate(from: graph)

        let hasAligned = transformations.contains { transformation in
            if case .removal(.aligned) = transformation.operation { return true }
            return false
        }
        #expect(hasAligned)
    }
}
