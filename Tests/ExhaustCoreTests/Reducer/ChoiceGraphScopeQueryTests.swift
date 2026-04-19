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

    @Test("Covering aligned removal scope for zip of two sequences")
    func coveringAlignedRemovalTwoSequences() {
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
        let coveringScopes = RemovalScopeQuery.coveringAlignedRemovalScopes(graph: graph)

        // One covering scope per zip node with deletable sibling sequences.
        #expect(coveringScopes.count == 1)
        #expect(coveringScopes[0].siblings.count == 2)
        #expect(coveringScopes[0].maxElementYield > 0)
        // Domain sizes: 3+1=4 for seq1, 2+1=3 for seq2.
        #expect(coveringScopes[0].skipValues == [3, 2])
    }

    @Test("No covering aligned removal for zip of non-sequence children")
    func noCoveringAlignedRemovalForLeaves() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let coveringScopes = RemovalScopeQuery.coveringAlignedRemovalScopes(graph: graph)

        #expect(coveringScopes.isEmpty)
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
        let singleTargetScopes = RemovalScopeQuery.elementRemovalScopes(graph: graph).filter { $0.targets.count == 1 }

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
        let singleTargetScopes = RemovalScopeQuery.elementRemovalScopes(graph: graph).filter { $0.targets.count == 1 }

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
        let scopes = MinimizationScopeQuery.build(graph: graph)

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
        let scopes = MinimizationScopeQuery.build(graph: graph)

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
        let scopes = PermutationScopeQuery.build(graph: graph)

        #expect(scopes.count == 1)
        if case let .siblingPermutation(scope) = scopes.first {
            #expect(scope.swappableGroups.count == 1)
            #expect(scope.swappableGroups[0].count == 2)
        }
    }

    // MARK: - Enumerator Integration

    // MARK: - Aligned Removal Encoder

    @Test("Covering aligned removal encoder produces candidates removing from multiple sequences")
    func coveringAlignedRemovalProducesCandidates() {
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

        let alignedScopes = RemovalScopeQuery.coveringAlignedRemovalScopes(graph: graph)
        guard let coveringScope = alignedScopes.first else {
            Issue.record("No covering aligned removal scope found")
            return
        }

        let transformation = GraphTransformation(
            operation: .remove(.coveringAligned(coveringScope)),
            yield: TransformationYield(
                structural: coveringScope.maxElementYield,
                value: 0,
                slack: .exact,
                estimatedProbes: coveringScope.handle.generator.totalRemaining
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

        var encoder = GraphStructuralEncoder()
        encoder.start(scope: scope)

        var candidates: [ChoiceSequence] = []
        var lastAccepted = false
        while let probe = encoder.nextProbe(lastAccepted: lastAccepted) {
            candidates.append(probe.candidate)
            lastAccepted = false
        }

        #expect(candidates.isEmpty == false)
        // Covering aligned removal removes from at least two sequences
        // simultaneously, so candidates should be shorter by at least 2.
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

    @Test("Enumerator includes covering aligned removal for zip of sequences")
    func enumeratorIncludesCoveringAligned() {
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

        let hasCoveringAligned = transformations.contains { transformation in
            if case .remove(.coveringAligned) = transformation.operation {
                return true
            }
            return false
        }
        #expect(hasCoveringAligned)
    }

    // MARK: - Inner Descendant Index

    @Test("Scalar bind-inner leaf is indexed to its bind")
    func innerDescendantIndexScalar() {
        let inner = ChoiceTree.choice(.unsigned(3, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let bound = ChoiceTree.choice(.unsigned(5, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let tree = ChoiceTree.bind(fingerprint: 0, inner: inner, bound: bound)
        let graph = ChoiceGraph.build(from: tree)
        let index = ScopeQueryHelpers.buildInnerDescendantToBind(graph: graph)

        let bindNodeID = graph.nodes.first { if case .bind = $0.kind { return true } else { return false } }?.id
        #expect(bindNodeID != nil)
        guard let bindNodeID else { return }

        guard case let .bind(metadata) = graph.nodes[bindNodeID].kind else { return }
        let innerLeafID = graph.nodes[bindNodeID].children[metadata.innerChildIndex]
        let boundLeafID = graph.nodes[bindNodeID].children[metadata.boundChildIndex]

        #expect(index[innerLeafID] == bindNodeID)
        #expect(index[boundLeafID] == nil)
        #expect(ScopeQueryHelpers.isBindInner(innerLeafID, innerDescendantToBind: index))
        #expect(ScopeQueryHelpers.isBindInner(boundLeafID, innerDescendantToBind: index) == false)
    }

    @Test("Multi-leaf bind-inner leaves are all indexed to the bind")
    func innerDescendantIndexMultiLeafSequence() {
        // Inner is a sequence of three leaves; bound is a single leaf.
        let innerSequence = ChoiceTree.sequence(
            length: 3,
            elements: [
                .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(.unsigned(3, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let bound = ChoiceTree.choice(.unsigned(7, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let tree = ChoiceTree.bind(fingerprint: 0, inner: innerSequence, bound: bound)
        let graph = ChoiceGraph.build(from: tree)
        let index = ScopeQueryHelpers.buildInnerDescendantToBind(graph: graph)

        let bindNodeID = graph.nodes.first { if case .bind = $0.kind { return true } else { return false } }?.id
        #expect(bindNodeID != nil)
        guard let bindNodeID else { return }

        guard case let .bind(metadata) = graph.nodes[bindNodeID].kind else { return }
        let innerContainerID = graph.nodes[bindNodeID].children[metadata.innerChildIndex]
        let boundLeafID = graph.nodes[bindNodeID].children[metadata.boundChildIndex]

        // Collect chooseBits descendants of the inner sequence.
        var innerLeafIDs: [Int] = []
        var stack = [innerContainerID]
        while let current = stack.popLast() {
            let node = graph.nodes[current]
            if case .chooseBits = node.kind {
                innerLeafIDs.append(current)
            }
            stack.append(contentsOf: node.children)
        }
        #expect(innerLeafIDs.count == 3)

        // Every inner-subtree leaf maps to the bind.
        for leafID in innerLeafIDs {
            #expect(index[leafID] == bindNodeID, "Inner leaf \(leafID) should map to bind \(bindNodeID)")
            #expect(ScopeQueryHelpers.isBindInner(leafID, innerDescendantToBind: index))
        }
        // The container itself is not indexed (only chooseBits leaves are).
        #expect(index[innerContainerID] == nil)
        // The bound leaf is untouched.
        #expect(index[boundLeafID] == nil)
    }

    @Test("Multi-leaf inner leaves receive reshape-on-accept marker")
    func multiLeafInnerReshapeMarker() {
        let innerSequence = ChoiceTree.sequence(
            length: 2,
            elements: [
                .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let bound = ChoiceTree.choice(.unsigned(5, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let tree = ChoiceTree.bind(fingerprint: 0, inner: innerSequence, bound: bound)
        let graph = ChoiceGraph.build(from: tree)
        let index = ScopeQueryHelpers.buildInnerDescendantToBind(graph: graph)

        let scopes = MinimizationScopeQuery.build(graph: graph, innerDescendantToBind: index)
        guard case let .valueLeaves(integerScope) = scopes.first(where: { if case .valueLeaves = $0 { return true } else { return false } }) else {
            Issue.record("Expected integer-leaves scope")
            return
        }

        // Collect inner-descendant leaf IDs so we can check their entries.
        let bindNodeID = graph.nodes.first { if case .bind = $0.kind { return true } else { return false } }?.id
        guard let bindNodeID, case let .bind(metadata) = graph.nodes[bindNodeID].kind else { return }
        let innerContainerID = graph.nodes[bindNodeID].children[metadata.innerChildIndex]
        var innerLeafIDs: Set<Int> = []
        var stack = [innerContainerID]
        while let current = stack.popLast() {
            let node = graph.nodes[current]
            if case .chooseBits = node.kind {
                innerLeafIDs.insert(current)
            }
            stack.append(contentsOf: node.children)
        }

        // Every inner-subtree leaf entry must carry the reshape marker.
        for entry in integerScope.leaves where innerLeafIDs.contains(entry.nodeID) {
            #expect(entry.mayReshapeOnAcceptance, "Inner leaf \(entry.nodeID) missing mayReshapeOnAcceptance")
        }
    }

    @Test("Nested binds: descendants are claimed by the outermost enclosing bind")
    func innerDescendantIndexNested() {
        // outerBind.inner = (innerBind.inner = leafA, innerBind.bound = leafB) placed inside an outer bind.
        // That would put leafA inside both innerBind.inner and outerBind.inner subtree.
        let leafA = ChoiceTree.choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let leafB = ChoiceTree.choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let innerBind = ChoiceTree.bind(fingerprint: 0, inner: leafA, bound: leafB)
        let leafOuterBound = ChoiceTree.choice(.unsigned(3, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let outerBind = ChoiceTree.bind(fingerprint: 0, inner: innerBind, bound: leafOuterBound)

        let graph = ChoiceGraph.build(from: outerBind)
        let index = ScopeQueryHelpers.buildInnerDescendantToBind(graph: graph)

        // Identify the two bind nodes; outer appears first (lower ID).
        let bindIDs = graph.nodes.compactMap { node -> Int? in
            if case .bind = node.kind { return node.id }
            return nil
        }
        #expect(bindIDs.count == 2)
        guard bindIDs.count == 2 else { return }
        let outerBindID = bindIDs[0]
        let innerBindID = bindIDs[1]

        // Find leafA — the sole chooseBits leaf inside the inner bind's inner subtree, which is also inside the outer bind's inner subtree.
        guard case let .bind(outerMeta) = graph.nodes[outerBindID].kind,
              case let .bind(innerMeta) = graph.nodes[innerBindID].kind else { return }
        let innerBindInnerContainerID = graph.nodes[innerBindID].children[innerMeta.innerChildIndex]
        // Since leafA is directly the inner bind's inner child, innerBindInnerContainerID IS leafA.
        let leafAID = innerBindInnerContainerID

        // Claim goes to the outer bind (outermost-wins): leafA is inside both inner and outer inner subtrees, outermost wins.
        #expect(index[leafAID] == outerBindID)

        // leafB (inner bind's bound) is NOT inside inner bind's inner subtree, but IS inside outer bind's inner subtree (everything under innerBind is, including its bound). So it is claimed by the outer bind.
        let leafBID = graph.nodes[innerBindID].children[innerMeta.boundChildIndex]
        #expect(index[leafBID] == outerBindID)

        // The outer bind's bound leaf is not in any inner subtree.
        let outerBoundID = graph.nodes[outerBindID].children[outerMeta.boundChildIndex]
        #expect(index[outerBoundID] == nil)
    }
}
