import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Generated exchange pair cursors")
struct ExchangePairCursorTests {
    @Test("Lookahead retains the exact heterogeneous sibling window and asymmetric zip leaf limits")
    func lookaheadBoundaries() {
        let mixedLeaves = (0 ..< 75).map { index in
            choice(UInt64(index + 1), tag: index.isMultiple(of: 2) ? .uint64 : .uint32)
        }
        let heterogeneous = sequence(mixedLeaves)
        let graph = ChoiceGraph.build(from: .group([heterogeneous, sequence(mixedLeaves.reversed())]))
        let expected = EagerExchangeReference.typeCompatibilityEdges(graph: graph)
        var cursor = TypeCompatibilityCursor(graph: graph)
        #expect(drain(&cursor) == expected)
        #expect(cursor.edgeCount == expected.count)
        let leftLeaves = graph.leafNodes.prefix(75)
        let rightLeaves = Set(graph.leafNodes.suffix(75))
        let crossEdges = expected.filter { leftLeaves.contains($0.nodeA) && rightLeaves.contains($0.nodeB) }
        #expect(crossEdges.count == 51 * 50)
        #expect(Set(crossEdges.map(\.nodeA)).count == 51)
        #expect(Set(crossEdges.map(\.nodeB)).count == 50)
    }

    @Test("Generated and buffered cursors support independent copies and ignore feedback")
    func independentCopies() {
        let graph = ChoiceGraph.build(from: .group([
            .uint64Sequence([9, 8, 8, 3]),
            .uint64Sequence([1, 2]),
            .uint64Sequence([4]),
        ]))
        let expected = EagerExchangeReference.redistributionPairs(graph: graph)
        var generated = GeneratedRedistributionPairCursor(graph: graph)
        var copied = generated
        var buffered = BufferedScopeCursor(expected)
        #expect(signature(generated.next()) == signature(buffered.next()))
        #expect(signature(generated.next()) == signature(buffered.next()))
        #expect(drain(&copied).map(signature) == expected.map(signature))
        #expect(drain(&generated).map(signature) == drain(&buffered).map(signature))
        #expect(generated.next() == nil)
        #expect(buffered.next() == nil)
    }

    @Test("Exchange scopes retain independent cursors and preserve bounded encoder pair selection")
    func encoderSelectionMatchesEager() throws {
        let tree = ChoiceTree.group((0 ..< 12).map { index in
            ChoiceTree.uint64Sequence([UInt64(index + 1000), 800, 800, 300, 0], in: 0 ... 10000)
        })
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)
        let scope = try #require(ExchangeQuery.build(graph: graph).compactMap { scope -> RedistributionScope? in
            guard case let .redistribution(redistribution) = scope else {
                return nil
            }
            return redistribution
        }.first)
        let expected = EagerExchangeReference.redistributionPairs(graph: graph)
        #expect(scope.pairCount == expected.count)
        #expect(scope.pairs.map(signature) == expected.map(signature))
        var first = scope.pairCursor()
        var second = scope.pairCursor()
        _ = first.next()
        #expect(drain(&second).map(signature) == expected.map(signature))

        var generatedEncoder = GraphRedistributionEncoder()
        generatedEncoder.valueState.reset(sequence: sequence)
        generatedEncoder.startRedistribution(scope: scope, graph: graph)
        var eagerEncoder = GraphRedistributionEncoder()
        eagerEncoder.valueState.reset(sequence: sequence)
        eagerEncoder.startRedistribution(pairs: expected, graph: graph)
        guard case let .active(generatedState) = generatedEncoder.mode,
              case let .active(eagerState) = eagerEncoder.mode
        else {
            Issue.record("Expected both encoders to have redistribution pairs")
            return
        }
        #expect(generatedState.pairs.map(\.sourceIndex) == eagerState.pairs.map(\.sourceIndex))
        #expect(generatedState.pairs.map(\.sinkIndex) == eagerState.pairs.map(\.sinkIndex))
        #expect(generatedState.pairs.count == GraphRedistributionEncoder.maxPairsPerScope)
        var generatedCandidate = sequence
        var eagerCandidate = sequence
        var lastAccepted = false
        var emitted = 0
        while generatedEncoder.nextProbe(into: &generatedCandidate, lastAccepted: lastAccepted) != nil {
            #expect(eagerEncoder.nextProbe(into: &eagerCandidate, lastAccepted: lastAccepted) != nil)
            #expect(generatedCandidate == eagerCandidate)
            // Delay acceptance until binary search has emitted several deltas, then force subsequent pairs and replay passes to recompute from the evolving baseline.
            lastAccepted = emitted % 17 == 16
            emitted += 1
        }
        #expect(eagerEncoder.nextProbe(into: &eagerCandidate, lastAccepted: lastAccepted) == nil)
        #expect(emitted > 30)
    }

    @Test("Exchange cursors do not retain mutable graph nodes")
    func graphBufferRemainsWritable() throws {
        var graph = ChoiceGraph.build(from: .group([.uint64Sequence([3, 2]), .uint64Sequence([1, 4])]))
        var edges = TypeCompatibilityCursor(graph: graph)
        var pairs = GeneratedRedistributionPairCursor(graph: graph)
        let leafNodeID = try #require(graph.leafNodes.first)
        let address = graph.nodes.withUnsafeBufferPointer { $0.baseAddress }
        guard case let .chooseBits(metadata) = graph.nodes[leafNodeID].kind else {
            Issue.record("Expected a value leaf")
            return
        }
        graph.nodes[leafNodeID] = graph.nodes[leafNodeID].with(kind: .chooseBits(ChooseBitsMetadata(
            typeTag: metadata.typeTag,
            validRange: metadata.validRange,
            isRangeExplicit: metadata.isRangeExplicit,
            value: ChoiceValue(UInt64(12), tag: metadata.typeTag),
            typeTagPayload: metadata.typeTagPayload
        )))
        #expect(graph.nodes.withUnsafeBufferPointer { $0.baseAddress } == address)
        #expect(edges.next() != nil || edges.edgeCount == 0)
        #expect(pairs.next() != nil)
    }

    @Test("A million-edge zip retains linear descriptors and can emit a short prefix")
    func wideCompatibilityPrefix() {
        let count = 1500
        let graph = ChoiceGraph.build(from: .group((0 ..< count).map { index in .uint64(UInt64(index + 1)) }))
        var cursor = TypeCompatibilityCursor(graph: graph)
        #expect(cursor.edgeCount == count * (count - 1) / 2)
        #expect(cursor.preparedLeafCount == count)
        #expect(ChoiceGraphStats.from(graph).typeCompatibilityEdgeCount == cursor.edgeCount)
        let nodeIDs = graph.leafNodes
        for index in 1 ... 32 {
            let edge = cursor.next()
            #expect(edge?.nodeA == nodeIDs[0])
            #expect(edge?.nodeB == nodeIDs[index])
        }
    }

    @Test("Nested zip prefix memoization preserves depth-first edge ordering")
    func nestedZipPrefixes() {
        var tree = ChoiceTree.uint64(7)
        for index in 0 ..< 100 {
            tree = .group([.just, .uint64(UInt64(index + 1)), tree])
        }
        let graph = ChoiceGraph.build(from: tree)
        let expectedEdges = EagerExchangeReference.typeCompatibilityEdges(graph: graph)
        var edges = TypeCompatibilityCursor(graph: graph)
        #expect(edges.edgeCount == expectedEdges.count)
        #expect(drain(&edges) == expectedEdges)
        let expectedPairs = EagerExchangeReference.redistributionPairs(graph: graph)
        var pairs = GeneratedRedistributionPairCursor(graph: graph)
        #expect(pairs.summary().pairCount == expectedPairs.count)
        #expect(drain(&pairs).map(signature) == expectedPairs.map(signature))
    }

    @Test("Wide homogeneous zips count all pairs while scopes retain only prepared domains")
    func wideHomogeneousScope() throws {
        let count = 200
        let graph = ChoiceGraph.build(from: .group((0 ..< count).map { _ in .uint64Sequence([1, 2]) }))
        let scope = try #require(ExchangeQuery.build(graph: graph).compactMap { scope -> RedistributionScope? in
            guard case let .redistribution(redistribution) = scope else {
                return nil
            }
            return redistribution
        }.first)
        #expect(scope.pairCount == count + count * (count - 1))
        #expect(scope.maximumSourceDistance == 2)
        var cursor = scope.pairCursor()
        for _ in 0 ..< 32 {
            #expect(cursor.next() != nil)
        }
    }

    private struct PairSignature: Equatable {
        let source: Int
        let sink: Int
        let sourceTag: TypeTag
        let sinkTag: TypeTag
        let sourceMayReshape: Bool
        let sinkMayReshape: Bool
        let sourceBindDepth: Int?
        let sinkBindDepth: Int?
    }

    private func signature(_ pair: RedistributionPair) -> PairSignature {
        PairSignature(
            source: pair.source.nodeID,
            sink: pair.sink.nodeID,
            sourceTag: pair.sourceTag,
            sinkTag: pair.sinkTag,
            sourceMayReshape: pair.source.mayReshapeOnAcceptance,
            sinkMayReshape: pair.sink.mayReshapeOnAcceptance,
            sourceBindDepth: pair.source.bindDepth,
            sinkBindDepth: pair.sink.bindDepth
        )
    }

    private func signature(_ pair: RedistributionPair?) -> PairSignature? {
        pair.map(signature)
    }

    private func drain<Cursor: ScopeCursor>(_ cursor: inout Cursor) -> [Cursor.Scope] {
        var scopes: [Cursor.Scope] = []
        while let scope = cursor.next() {
            scopes.append(scope)
        }
        return scopes
    }

    private func choice(_ value: UInt64, tag: TypeTag) -> ChoiceTree {
        .choice(ChoiceValue(value, tag: tag), .init(validRange: nil, isRangeExplicit: false))
    }

    private func sequence(_ elements: some Sequence<ChoiceTree>) -> ChoiceTree {
        .sequence(elements: Array(elements), metadata: .init(validRange: nil, isRangeExplicit: false))
    }
}
