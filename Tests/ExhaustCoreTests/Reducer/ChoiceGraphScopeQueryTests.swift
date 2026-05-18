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
                .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let seq2 = ChoiceTree.sequence(
            length: 2,
            elements: [
                .choice(ChoiceValue(4 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(ChoiceValue(5 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let tree = ChoiceTree.group([seq1, seq2])
        let graph = ChoiceGraph.build(from: tree)
        let coveringScopes = RemovalQuery.coveringAlignedRemovalScopes(graph: graph)

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
            .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let coveringScopes = RemovalQuery.coveringAlignedRemovalScopes(graph: graph)

        #expect(coveringScopes.isEmpty)
    }

    // MARK: - Element Removal (Per-Parent)

    @Test("Per-parent removal for simple sequence")
    func perParentRemovalSimple() {
        let tree = ChoiceTree.sequence(
            length: 3,
            elements: [
                .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let graph = ChoiceGraph.build(from: tree)
        let singleTargetScopes = RemovalQuery.elementRemovalScopes(graph: graph).filter { $0.targets.count == 1 }

        #expect(singleTargetScopes.count == 1)
        #expect(singleTargetScopes[0].targets[0].elementNodeIDs.count == 3)
        #expect(singleTargetScopes[0].maxBatch == 3)
    }

    @Test("Per-parent removal respects length constraint")
    func perParentRemovalConstrained() {
        let tree = ChoiceTree.sequence(
            length: 3,
            elements: [
                .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: 2 ... 5, isRangeExplicit: true)
        )
        let graph = ChoiceGraph.build(from: tree)
        let singleTargetScopes = RemovalQuery.elementRemovalScopes(graph: graph).filter { $0.targets.count == 1 }

        #expect(singleTargetScopes.count == 1)
        #expect(singleTargetScopes[0].maxBatch == 1)
    }

    // MARK: - Minimization

    @Test("Integer minimization scope collects non-zero leaves")
    func integerMinimizationScope() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(42 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(ChoiceValue(99 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let scopes = MinimizationQuery.build(graph: graph)

        let integerScopes = scopes.filter {
            if case .valueLeaves = $0 { return true }
            return false
        }
        #expect(integerScopes.count == 1)
        if case let .valueLeaves(scope) = integerScopes.first {
            #expect(scope.leaves.count == 2)
            #expect(scope.batchZeroEligible)
        }
    }

    @Test("Minimization scope excludes already-converged leaves")
    func minimizationSkipsConverged() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(0 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(ChoiceValue(0 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let scopes = MinimizationQuery.build(graph: graph)

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
                .choice(ChoiceValue(5 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let seq2 = ChoiceTree.sequence(
            length: 1,
            elements: [
                .choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let tree = ChoiceTree.group([seq1, seq2])
        let graph = ChoiceGraph.build(from: tree)
        let scopes = PermutationQuery.build(graph: graph)

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
                .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
                .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
                .choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let seq2 = ChoiceTree.sequence(
            length: 2,
            elements: [
                .choice(ChoiceValue(4 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
                .choice(ChoiceValue(5 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let tree = ChoiceTree.group([seq1, seq2])
        let sequence = ChoiceSequence.flatten(tree)
        let graph = ChoiceGraph.build(from: tree)

        let alignedScopes = RemovalQuery.coveringAlignedRemovalScopes(graph: graph)
        guard let coveringScope = alignedScopes.first else {
            Issue.record("No covering aligned removal scope found")
            return
        }

        let transformation = GraphTransformation(
            operation: .remove(.coveringAligned(coveringScope)),
            priority: DispatchPriority(
                structuralBenefit: coveringScope.maxElementYield,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: coveringScope.generator.totalRemaining
            ),
        )
        let scope = EncoderInput(
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
        var candidateBuffer = sequence
        while encoder.nextProbe(into: &candidateBuffer, lastAccepted: lastAccepted) != nil {
            candidates.append(candidateBuffer)
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

    // MARK: - Scope Annotation: Bind-Inner Classification

    @Test("Scalar bind-inner leaf is annotated as bind-inner")
    func scopeAnnotationScalar() {
        let inner = ChoiceTree.choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let bound = ChoiceTree.choice(ChoiceValue(5 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let tree = ChoiceTree.bind(fingerprint: 0, inner: inner, bound: bound)
        let graph = ChoiceGraph.build(from: tree)

        let bindNodeID = graph.nodes.first { if case .bind = $0.kind { true } else { false } }?.id
        #expect(bindNodeID != nil)
        guard let bindNodeID else { return }

        guard case let .bind(metadata) = graph.nodes[bindNodeID].kind else { return }
        let innerLeafID = graph.nodes[bindNodeID].children[metadata.innerChildIndex]
        let boundLeafID = graph.nodes[bindNodeID].children[metadata.boundChildIndex]

        #expect(graph.nodes[innerLeafID].scopeAnnotation.isBindInner)
        #expect(graph.nodes[innerLeafID].scopeAnnotation.controllingBindNodeID == bindNodeID)
        #expect(graph.nodes[boundLeafID].scopeAnnotation.isBindInner == false)
        #expect(graph.nodes[boundLeafID].scopeAnnotation.controllingBindNodeID == nil)
    }

    @Test("Multi-leaf bind-inner leaves are all annotated as bind-inner")
    func scopeAnnotationMultiLeafSequence() {
        let innerSequence = ChoiceTree.sequence(
            length: 3,
            elements: [
                .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let bound = ChoiceTree.choice(ChoiceValue(7 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let tree = ChoiceTree.bind(fingerprint: 0, inner: innerSequence, bound: bound)
        let graph = ChoiceGraph.build(from: tree)

        let bindNodeID = graph.nodes.first { if case .bind = $0.kind { true } else { false } }?.id
        #expect(bindNodeID != nil)
        guard let bindNodeID else { return }

        guard case let .bind(metadata) = graph.nodes[bindNodeID].kind else { return }
        let innerContainerID = graph.nodes[bindNodeID].children[metadata.innerChildIndex]
        let boundLeafID = graph.nodes[bindNodeID].children[metadata.boundChildIndex]

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

        for leafID in innerLeafIDs {
            #expect(graph.nodes[leafID].scopeAnnotation.isBindInner, "Inner leaf \(leafID) should be annotated as bind-inner")
            #expect(graph.nodes[leafID].scopeAnnotation.controllingBindNodeID == bindNodeID)
        }
        #expect(graph.nodes[boundLeafID].scopeAnnotation.isBindInner == false)
    }

    @Test("Multi-leaf inner leaves receive reshape-on-accept marker via annotation")
    func multiLeafInnerReshapeMarker() {
        let innerSequence = ChoiceTree.sequence(
            length: 2,
            elements: [
                .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            .init(validRange: nil, isRangeExplicit: false)
        )
        let bound = ChoiceTree.choice(ChoiceValue(5 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let tree = ChoiceTree.bind(fingerprint: 0, inner: innerSequence, bound: bound)
        let graph = ChoiceGraph.build(from: tree)

        let scopes = MinimizationQuery.build(graph: graph)
        guard case let .valueLeaves(integerScope) = scopes.first(where: { if case .valueLeaves = $0 { true } else { false } }) else {
            Issue.record("Expected integer-leaves scope")
            return
        }

        let bindNodeID = graph.nodes.first { if case .bind = $0.kind { true } else { false } }?.id
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

        for entry in integerScope.leaves where innerLeafIDs.contains(entry.nodeID) {
            #expect(entry.mayReshapeOnAcceptance, "Inner leaf \(entry.nodeID) missing mayReshapeOnAcceptance")
        }
    }

    @Test("Nested binds: descendants are claimed by the outermost enclosing bind")
    func scopeAnnotationNested() {
        let leafA = ChoiceTree.choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let leafB = ChoiceTree.choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let innerBind = ChoiceTree.bind(fingerprint: 0, inner: leafA, bound: leafB)
        let leafOuterBound = ChoiceTree.choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let outerBind = ChoiceTree.bind(fingerprint: 0, inner: innerBind, bound: leafOuterBound)

        let graph = ChoiceGraph.build(from: outerBind)

        let bindIDs = graph.nodes.compactMap { node -> Int? in
            if case .bind = node.kind { return node.id }
            return nil
        }
        #expect(bindIDs.count == 2)
        guard bindIDs.count == 2 else { return }
        let outerBindID = bindIDs[0]
        let innerBindID = bindIDs[1]

        guard case let .bind(outerMeta) = graph.nodes[outerBindID].kind,
              case let .bind(innerMeta) = graph.nodes[innerBindID].kind else { return }
        let leafAID = graph.nodes[innerBindID].children[innerMeta.innerChildIndex]

        #expect(graph.nodes[leafAID].scopeAnnotation.controllingBindNodeID == outerBindID)

        let leafBID = graph.nodes[innerBindID].children[innerMeta.boundChildIndex]
        #expect(graph.nodes[leafBID].scopeAnnotation.controllingBindNodeID == outerBindID)

        let outerBoundID = graph.nodes[outerBindID].children[outerMeta.boundChildIndex]
        #expect(graph.nodes[outerBoundID].scopeAnnotation.isBindInner == false)
        #expect(graph.nodes[outerBoundID].scopeAnnotation.controllingBindNodeID == nil)
    }
}
