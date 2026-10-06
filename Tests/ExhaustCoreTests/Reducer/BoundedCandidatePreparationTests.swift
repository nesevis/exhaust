import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Bounded candidate preparation")
struct BoundedCandidatePreparationTests {
    @Test("Bounded sorting retains the eager stable prefix, including ties and zero limits", arguments: [0, 1, 30, 100])
    func stableBoundedSorting(limit: Int) {
        let values = (0 ..< 200).map { index in (priority: index % 11, discovery: index) }
        var buffer = BoundedSortedBuffer<(priority: Int, discovery: Int)>(limit: limit)
        for value in values {
            buffer.insert(value) { $0.priority > $1.priority }
            #expect(buffer.elements.count <= limit)
        }
        let expected = values.sorted { $0.priority > $1.priority }.prefix(limit)
        #expect(buffer.elements.map(\.discovery) == expected.map(\.discovery))
    }

    @Test("Sparse redistribution comparisons match materialized shortlex for mixed and overlapping pairs")
    func sparseRedistributionOrdering() throws {
        let fixture = redistributionFixture()
        var encoder = GraphRedistributionEncoder()
        encoder.valueState.reset(sequence: fixture.sequence)
        let prepared = fixture.pairs.compactMap { encoder.preparePair($0, graph: fixture.graph) }
        let edits = prepared.compactMap { pair in
            encoder.redistributionEdit(
                sourceIndex: pair.sourceIndex,
                sinkIndex: pair.sinkIndex,
                sourceTag: pair.sourceTag,
                delta: pair.maxDelta,
                mixedContext: pair.mixedContext
            )
        }
        #expect(edits.count > GraphRedistributionEncoder.maxPairsPerScope)
        for first in edits.prefix(45) {
            for second in edits.suffix(45) {
                #expect(first.shortLexPrecedes(second, sequence: fixture.sequence)
                    == first.applying(to: fixture.sequence).shortLexPrecedes(second.applying(to: fixture.sequence)))
            }
        }
        let position = try #require(prepared.first?.sourceIndex)
        let entry = fixture.sequence[position]
        let overlapping = GraphRedistributionEncoder.RedistributionEdit(
            sourceIndex: position,
            sinkIndex: position,
            sourceEntry: entry.withBitPattern(0),
            sinkEntry: entry
        )
        #expect(overlapping.applying(to: fixture.sequence) == fixture.sequence)
        #expect(overlapping.shortLexPrecedes(overlapping, sequence: fixture.sequence) == false)
    }

    @Test("Redistribution retains the original eager top 30 and registers only selected leaves")
    func redistributionMatchesEagerPrefix() throws {
        let fixture = redistributionFixture()
        var encoder = GraphRedistributionEncoder()
        encoder.valueState.reset(sequence: fixture.sequence)
        let pairs = fixture.pairs.compactMap { encoder.preparePair($0, graph: fixture.graph) }
        let candidates = pairs.map { pair in
            encoder.buildRedistributionCandidate(
                sourceIndex: pair.sourceIndex,
                sinkIndex: pair.sinkIndex,
                sourceTag: pair.sourceTag,
                sinkTag: pair.sinkTag,
                delta: pair.maxDelta,
                mixedContext: pair.mixedContext
            )
        }
        #expect(candidates.contains { $0 == nil })
        let expected = pairs.indices.sorted { first, second in
            switch (candidates[first], candidates[second]) {
                case let (.some(firstCandidate), .some(secondCandidate)):
                    firstCandidate.shortLexPrecedes(secondCandidate)
                case (.some, .none):
                    true
                case (.none, .some):
                    false
                case (.none, .none):
                    pairs[first].maxDelta > pairs[second].maxDelta
            }
        }.prefix(GraphRedistributionEncoder.maxPairsPerScope)
        encoder.startRedistribution(pairs: fixture.pairs, graph: fixture.graph)
        guard case let .active(state) = encoder.mode else {
            Issue.record("Expected active redistribution")
            return
        }
        #expect(state.pairs.map(\.sourceIndex) == expected.map { pairs[$0].sourceIndex })
        #expect(state.pairs.map(\.sinkIndex) == expected.map { pairs[$0].sinkIndex })
        let positions = Set(state.pairs.flatMap { [$0.sourceIndex, $0.sinkIndex] })
        #expect(Set(encoder.valueState.leafLookup.keys) == positions)
        var candidate = fixture.sequence
        let probe = encoder.nextProbe(into: &candidate, lastAccepted: false)
        #expect(probe != nil)
        let firstExpected = try #require(expected.first)
        #expect(candidate == candidates[firstExpected])
    }

    @Test("Relax cursor preserves eager length order and exact candidate count", arguments: [0, 1, 3, 1000])
    func relaxMatchesEagerPrefix(limit: Int) {
        let nested = pick(content: .uint64Zip([5, 6]))
        let tree = ChoiceTree.group([
            pick(content: .group([.uint64(9), nested])),
            pick(content: .uint64Zip([2, 3])),
            pick(content: .uint64Zip([2, 3])),
            pick(content: .uint64Zip([8, 7, 6])),
            pick(content: .uint64(1)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)
        let expected = eagerRelaxCandidates(sequence: sequence, graph: graph)
        var cursor = RelaxCandidateCursor(sequence: sequence, graph: graph, limit: limit)
        var actual: [ChoiceSequence] = []
        while let candidate = cursor.next() {
            actual.append(candidate)
        }
        #expect(expected.isEmpty == false)
        #expect(cursor.candidateCount == expected.count)
        #expect(cursor.retainedCandidateCount == min(limit, expected.count))
        #expect(actual == Array(expected.prefix(limit)))
    }

    @Test("Relax no-op classification checks metadata despite operative hash collisions")
    func relaxNoOpMetadata() {
        let tree = ChoiceTree.group([
            pick(content: .sequence(elements: [.uint64(4)], metadata: .init(validRange: 0 ... 5, isRangeExplicit: true))),
            pick(content: .sequence(elements: [.uint64(4)], metadata: .init(validRange: 0 ... 6, isRangeExplicit: true))),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)
        let expected = eagerRelaxCandidates(sequence: sequence, graph: graph)
        var cursor = RelaxCandidateCursor(sequence: sequence, graph: graph, limit: 100)
        var actual: [ChoiceSequence] = []
        while let candidate = cursor.next() {
            actual.append(candidate)
        }
        #expect(actual == expected)
        #expect(cursor.candidateCount == expected.count)
        #expect(expected.contains { $0.count == sequence.count && $0 != sequence })
    }

    @Test("Relax length ranking includes depth-zero expansion before choosing the budgeted prefix")
    func depthCrossingRelaxOrder() throws {
        let inner = ChoiceTree.pickSite(fingerprint: 42, selected: 1, branches: [.uint64(0), .uint64Zip([1, 2])])
        let outer = ChoiceTree.pickSite(
            fingerprint: 42,
            selected: 1,
            branches: [.uint64(0), .group([inner, .uint64(9)], isZip: true)]
        )
        let tree = ChoiceTree.group([outer, inner, inner])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)
        let donors = graph.liveNodeIDs.filter { nodeID in
            if case .pick = graph.nodes[nodeID].kind {
                return true
            }
            return false
        }
        let expandedCounts = try donors.map { nodeID in
            let range = try #require(graph.nodes[nodeID].positionRange)
            let expanded = GraphStructuralEncoder.expandDepthZeroLeaves(
                Array(sequence[range]),
                donorNodeID: nodeID,
                donorRangeStart: range.lowerBound,
                graph: graph
            )
            return expanded.count - range.count
        }
        #expect(expandedCounts.contains { $0 > 0 })
        let expected = eagerRelaxCandidates(sequence: sequence, graph: graph)
        var cursor = RelaxCandidateCursor(sequence: sequence, graph: graph, limit: 5)
        var actual: [ChoiceSequence] = []
        while let candidate = cursor.next() {
            actual.append(candidate)
        }
        #expect(cursor.candidateCount == expected.count)
        #expect(actual == Array(expected.prefix(5)))
    }

    @Test("Wide families retain only budgeted splices across thousands of candidates")
    func wideFamilyBoundedPrefix() {
        let tree = ChoiceTree.group((0 ..< 150).map { index in
            pick(content: .uint64Zip([UInt64(index + 1), 3, 4]))
        })
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)
        var cursor = RelaxCandidateCursor(sequence: sequence, graph: graph, limit: 3)
        #expect(cursor.candidateCount > 10000)
        #expect(cursor.retainedCandidateCount == 3)
        var emitted = 0
        while cursor.next() != nil {
            emitted += 1
        }
        #expect(emitted == 3)
    }

    private func pick(content: ChoiceTree) -> ChoiceTree {
        .pickSite(fingerprint: 42, selected: 1, branches: [.just, content])
    }

    /// Keeps full-sequence sorting as an independent oracle for the cursor's bounded splice ranking.
    private func eagerRelaxCandidates(sequence: ChoiceSequence, graph: ChoiceGraph) -> [ChoiceSequence] {
        var candidates: [ChoiceSequence] = []
        for scope in EagerScopeReference.replacementScopes(graph: graph) {
            switch scope {
                case let .branchPivot(pickNodeID, targetBranchID):
                    if let candidate = GraphStructuralEncoder.branchPivotCandidate(
                        pickNodeID: pickNodeID,
                        targetBranchID: targetBranchID,
                        sequence: sequence,
                        graph: graph
                    ) {
                        candidates.append(candidate)
                    }
                case let .selfSimilar(targetNodeID, donorNodeID, _),
                     let .descendantPromotion(targetNodeID, donorNodeID, _):
                    guard let targetRange = graph.nodes[targetNodeID].positionRange,
                          let donorRange = graph.nodes[donorNodeID].positionRange
                    else {
                        continue
                    }
                    let expanded = GraphStructuralEncoder.expandDepthZeroLeaves(
                        Array(sequence[donorRange]),
                        donorNodeID: donorNodeID,
                        donorRangeStart: donorRange.lowerBound,
                        graph: graph
                    )
                    var candidate = sequence
                    candidate.replaceSubrange(targetRange, with: expanded)
                    if candidate != sequence {
                        candidates.append(candidate)
                    }
            }
        }
        candidates.sort { $0.count < $1.count }
        return candidates
    }

    private func redistributionFixture() -> (pairs: [RedistributionPair], graph: ChoiceGraph, sequence: ChoiceSequence) {
        let integers = (1 ... 40).map { value in
            ChoiceTree.choice(ChoiceValue(UInt64(value % 13 + 1), tag: .uint64), .init(validRange: 0 ... 15, isRangeExplicit: true))
        }
        let tree = ChoiceTree.group(integers + [
            .choice(ChoiceValue(Int16(-7), tag: .int16), .init(validRange: nil, isRangeExplicit: false)),
            .choice(ChoiceValue(2.5, tag: .double), .init(validRange: nil, isRangeExplicit: false)),
            .choice(ChoiceValue(1.25, tag: .double), .init(validRange: nil, isRangeExplicit: false)),
            .choice(ChoiceValue(UInt8(250), tag: .uint8), .init(validRange: nil, isRangeExplicit: false)),
            .choice(ChoiceValue(UInt8(255), tag: .uint8), .init(validRange: nil, isRangeExplicit: false)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let leaves = graph.liveNodeIDs.filter { nodeID in
            if case .chooseBits = graph.nodes[nodeID].kind {
                return true
            }
            return false
        }
        var pairs: [RedistributionPair] = []
        for first in leaves.indices {
            for second in leaves.indices where second > first {
                guard case let .chooseBits(sourceMetadata) = graph.nodes[leaves[first]].kind,
                      case let .chooseBits(sinkMetadata) = graph.nodes[leaves[second]].kind
                else {
                    continue
                }
                pairs.append(RedistributionPair(
                    source: LeafEntry(nodeID: leaves[first]),
                    sink: LeafEntry(nodeID: leaves[second]),
                    sourceTag: sourceMetadata.typeTag,
                    sinkTag: sinkMetadata.typeTag
                ))
            }
        }
        return (pairs, graph, ChoiceSequence.flatten(tree))
    }
}
