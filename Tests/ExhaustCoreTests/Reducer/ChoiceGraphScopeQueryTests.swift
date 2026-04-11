//
//  ChoiceGraphScopeQueryTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

// MARK: - Scope Query Tests

@Suite("ChoiceGraph Scope Queries")
struct ChoiceGraphScopeQueryTests {
    // MARK: - Element Removal (Aligned)

    @Test("Aligned element removal scope for zip of two sequences")
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
        let alignedScopes = graph.elementRemovalScopes().filter { $0.targets.count >= 2 }

        #expect(alignedScopes.count == 6)
        #expect(alignedScopes[0].targets.count == 2)
        #expect(alignedScopes[0].maxBatch == 1)
        #expect(alignedScopes[0].maxElementYield > 0)
    }

    @Test("No aligned removal for zip of non-sequence children")
    func noAlignedRemovalForLeaves() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let alignedScopes = graph.elementRemovalScopes().filter { $0.targets.count >= 2 }

        #expect(alignedScopes.isEmpty)
    }

    // MARK: - Element Removal (Per-Parent)

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
        let singleTargetScopes = graph.elementRemovalScopes().filter { $0.targets.count == 1 }

        #expect(singleTargetScopes.count == 1)
        #expect(singleTargetScopes[0].targets[0].elementNodeIDs.count == 3)
        #expect(singleTargetScopes[0].maxBatch == 3)
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
        let singleTargetScopes = graph.elementRemovalScopes().filter { $0.targets.count == 1 }

        #expect(singleTargetScopes.count == 1)
        #expect(singleTargetScopes[0].maxBatch == 1)
    }

    // MARK: - Minimization

    @Test("Integer minimization scope collects non-zero leaves")
    func integerMinimizationScope() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(42, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(.unsigned(99, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let scopes = graph.minimizationScopes()

        let integerScopes = scopes.filter {
            if case .valueLeaves = $0 { return true }
            return false
        }
        #expect(integerScopes.count == 1)
        if case let .valueLeaves(scope) = integerScopes.first {
            #expect(scope.leafNodeIDs.count == 2)
            #expect(scope.batchZeroEligible)
        }
    }

    @Test("Minimization scope excludes already-converged leaves")
    func minimizationSkipsConverged() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(0, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(.unsigned(0, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let scopes = graph.minimizationScopes()

        // Both leaves are at their reduction target (0) — no minimization scope.
        let integerScopes = scopes.filter {
            if case .valueLeaves = $0 { return true }
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

    @Test("Multi-target removal encoder produces candidates removing from all sequences")
    func multiTargetRemovalProducesCandidates() {
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

        let alignedScopes = graph.elementRemovalScopes().filter { $0.targets.count >= 2 }
        guard let elementScope = alignedScopes.first else {
            Issue.record("No multi-target removal scope found")
            return
        }

        let totalYield = elementScope.targets.reduce(0) { total, target in
            total + target.elementNodeIDs.reduce(0) { subtotal, nodeID in
                subtotal + (graph.nodes[nodeID].positionRange?.count ?? 0)
            }
        }

        let transformation = GraphTransformation(
            operation: .remove(.elements(elementScope)),
            yield: TransformationYield(
                structural: totalYield,
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
            candidates.append(probe.candidate)
            lastAccepted = false
        }

        #expect(candidates.isEmpty == false)
        // Multi-target removal removes from BOTH sequences simultaneously,
        // so candidates should be shorter by at least 2 (one element per target).
        for candidate in candidates {
            #expect(candidate.count < sequence.count)
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

    @Test("Enumerator includes multi-target removal for zip of sequences")
    func enumeratorIncludesMultiTarget() {
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

        let hasMultiTarget = transformations.contains { transformation in
            if case let .remove(.elements(scope)) = transformation.operation {
                return scope.targets.count >= 2
            }
            return false
        }
        #expect(hasMultiTarget)
    }
}
