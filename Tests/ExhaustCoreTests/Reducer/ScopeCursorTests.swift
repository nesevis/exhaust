import Testing
@testable import ExhaustCore

@Suite("Scope cursors")
struct ScopeCursorTests {
    @Test("Buffered enumeration preserves complete leaf groups")
    func bufferedGroupsRemainComplete() throws {
        let groupedScope = ValueMinimizationScope(
            leaves: [LeafEntry(nodeID: 1), LeafEntry(nodeID: 2)],
            batchZeroEligible: true
        )
        let singleScope = ValueMinimizationScope(
            leaves: [LeafEntry(nodeID: 3)],
            batchZeroEligible: false
        )
        var cursor = BufferedScopeCursor([groupedScope, singleScope])

        #expect(cursor.peekScope?.leaves.map(\.nodeID) == [1, 2])
        let first = try #require(nextScope(from: &cursor))
        let second = try #require(nextScope(from: &cursor))

        #expect(first.leaves.map(\.nodeID) == [1, 2])
        #expect(first.batchZeroEligible)
        #expect(second.leaves.map(\.nodeID) == [3])
        #expect(second.batchZeroEligible == false)
        #expect(nextScope(from: &cursor) == nil)
        #expect(nextScope(from: &cursor) == nil)
        #expect(cursor.peekScope == nil)
    }

    @Test("Empty buffered cursors remain exhausted")
    func emptyCursorIsExhausted() {
        var cursor = BufferedScopeCursor<ValueMinimizationScope>([])
        #expect(nextScope(from: &cursor) == nil)
        #expect(nextScope(from: &cursor) == nil)
        #expect(cursor.peekScope == nil)
    }

    @Test("Generated and buffered scopes drive the same encoder consumer in the same order")
    func generatedAndBufferedScopesProduceIdenticalProbes() throws {
        let tree = sequenceTree(values: Array(1 ... 8))
        let graph = ChoiceGraph.build(from: tree)
        let sequenceNodeID = try #require(graph.liveNodeIDs.first { nodeID in
            if case .sequence = graph.nodes[nodeID].kind {
                return true
            }
            return false
        })
        var generated = BatchRemovalSource(sequenceNodeID: sequenceNodeID, graph: graph)
        var preparation = generated
        var transformations: [GraphTransformation] = []
        while let transformation = nextScope(from: &preparation, lastAccepted: false) {
            transformations.append(transformation)
        }
        var buffered = SortedCandidateSource(transformations)

        let generatedProbes = try removalProbes(from: &generated, tree: tree, graph: graph)
        let bufferedProbes = try removalProbes(from: &buffered, tree: tree, graph: graph)

        #expect(generatedProbes == bufferedProbes)
        #expect(generatedProbes.map { candidate in
            candidate.compactMap { $0.value?.choice.bitPattern64 }
        } == [
            [1, 2, 3, 4],
            [5, 6, 7, 8],
            [1, 2, 3, 4, 5, 6],
            [3, 4, 5, 6, 7, 8],
            [1, 2, 3, 4, 5, 6, 7],
            [2, 3, 4, 5, 6, 7, 8],
        ])
        #expect(generated.peekPriority == nil)
        #expect(buffered.peekPriority == nil)
    }

    @Test("The source union forwards rejection and acceptance feedback to generated cursors")
    func generatedFeedbackSurvivesSourceUnion() throws {
        let tree = ChoiceTree.group([
            sequenceTree(values: [1, 2, 3, 4]),
            sequenceTree(values: [5, 6]),
        ])
        let graph = ChoiceGraph.build(from: tree)
        var source = AnyCandidateSource.batchedCrossSequence(BatchedCrossSequenceRemovalSource(graph: graph))
        let root = try #require(nextScope(from: &source, lastAccepted: false))
        let rootTargets = try #require(removalTargets(of: root))
        try #require(rootTargets.count == 2)
        var accepted = source

        #expect(nextScope(from: &accepted, lastAccepted: true) == nil)
        #expect(accepted.peekPriority == nil)

        let firstHalf = try #require(nextScope(from: &source, lastAccepted: false))
        let secondHalf = try #require(nextScope(from: &source, lastAccepted: false))
        #expect(removalTargets(of: firstHalf)?.map(\.sequenceNodeID) == [rootTargets[0].sequenceNodeID])
        #expect(removalTargets(of: secondHalf)?.map(\.sequenceNodeID) == [rootTargets[1].sequenceNodeID])
        #expect(nextScope(from: &source, lastAccepted: false) == nil)
        #expect(source.peekPriority == nil)
    }

    @Test("Scheduling merges buffered and generated priorities without consuming during inspection")
    func mixedSourcesPreserveScheduling() throws {
        let tree = ChoiceTree.group([
            sequenceTree(values: [1, 2, 3, 4]),
            sequenceTree(values: [5, 6]),
        ])
        let generated = BatchedCrossSequenceRemovalSource(graph: ChoiceGraph.build(from: tree))
        let generatedPriority = try #require(generated.peekPriority)
        let highest = transformation(nodeID: 100, benefit: generatedPriority.structuralBenefit + 1)
        let lowest = transformation(nodeID: 101, benefit: 0)
        var sources: [AnyCandidateSource] = [
            .batchedCrossSequence(generated),
            .sorted(SortedCandidateSource([highest, lowest])),
        ]

        #expect(ChoiceGraphScheduler.highestPrioritySourceIndex(sources) == 1)
        #expect(ChoiceGraphScheduler.highestPrioritySourceIndex(sources) == 1)
        let emitted = try #require(nextScope(from: &sources[1], lastAccepted: false))
        #expect(emitted.priority == highest.priority)
        #expect(ChoiceGraphScheduler.highestPrioritySourceIndex(sources) == 0)

        let tiedSources = [SortedCandidateSource([highest]), SortedCandidateSource([highest])]
        #expect(ChoiceGraphScheduler.highestPrioritySourceIndex(tiedSources) == 0)
        #expect(ChoiceGraphScheduler.highestPrioritySourceIndex([SortedCandidateSource([])]) == nil)
    }

    @Test("Invalidation metadata covers the complete buffered source and survives exhaustion")
    func invalidationMetadataSurvivesExhaustion() {
        let structural = transformation(nodeID: 1, benefit: 2)
        let value = GraphTransformation(
            operation: .minimize(.valueLeaves(ValueMinimizationScope(
                leaves: [LeafEntry(nodeID: 2)],
                batchZeroEligible: false
            ))),
            priority: .zeroBenefit
        )
        let permutation = GraphTransformation(
            operation: .permute(PermutationScope(parentNodeID: 3, swappableGroups: [[4, 5]])),
            priority: .zeroBenefit
        )
        var valueSource = AnyCandidateSource.sorted(SortedCandidateSource([structural, value]))
        var permutationSource = AnyCandidateSource.sorted(SortedCandidateSource([structural, permutation]))

        for _ in 0 ..< 3 {
            #expect(valueSource.isValueDependent)
            #expect(valueSource.canReuseAfterLeafKindChange == false)
            #expect(permutationSource.isPermutationSource)
            #expect(permutationSource.canReuseAfterLeafKindChange == false)
            _ = nextScope(from: &valueSource, lastAccepted: false)
            _ = nextScope(from: &permutationSource, lastAccepted: false)
        }
    }
}

// MARK: - Fixtures

private func nextScope<Cursor: ScopeCursor>(from cursor: inout Cursor) -> Cursor.Scope? {
    cursor.next()
}

private func nextScope(from source: inout some CandidateSource, lastAccepted: Bool) -> GraphTransformation? {
    source.next(lastAccepted: lastAccepted)
}

/// Exercises the encoder boundary through the shared cursor contract, preserving each emitted batch as one probe.
private func removalProbes<Cursor: ScopeCursor>(
    from cursor: inout Cursor,
    tree: ChoiceTree,
    graph: ChoiceGraph
) throws -> [ChoiceSequence] where Cursor.Scope == GraphTransformation {
    let sequence = ChoiceSequence(tree)
    var candidates: [ChoiceSequence] = []
    while let transformation = nextScope(from: &cursor) {
        guard case .remove(.elements) = transformation.operation else {
            continue
        }
        var encoder = GraphStructuralEncoder()
        encoder.start(scope: EncoderInput(
            transformation: transformation,
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        ))
        var candidate = sequence
        _ = try #require(encoder.nextProbe(into: &candidate, lastAccepted: false))
        #expect(encoder.nextProbe(into: &candidate, lastAccepted: false) == nil)
        candidates.append(candidate)
    }
    return candidates
}

private func removalTargets(of transformation: GraphTransformation) -> [SequenceRemovalTarget]? {
    guard case let .remove(.elements(scope)) = transformation.operation else {
        return nil
    }
    return scope.targets
}

private func sequenceTree(values: [UInt64]) -> ChoiceTree {
    .sequence(
        elements: values.map { value in
            .choice(ChoiceValue(value, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        },
        metadata: .init(validRange: nil, isRangeExplicit: false)
    )
}

private func transformation(nodeID: Int, benefit: Int) -> GraphTransformation {
    GraphTransformation(
        operation: .remove(.subtree(nodeID: nodeID, yield: benefit)),
        priority: DispatchPriority(
            structuralBenefit: benefit,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 1
        )
    )
}
