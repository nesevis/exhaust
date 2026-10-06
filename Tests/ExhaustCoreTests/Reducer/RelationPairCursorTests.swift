import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Indexed relation pair discovery")
struct RelationPairCursorTests {
    @Test("Indexed discovery preserves every eager pair and its positional order", arguments: [UInt64(1), 11, 42])
    func matchesEagerPairs(seed: UInt64) {
        let tags: [TypeTag] = [.uint8, .int8, .uint16, .int16, .uint32, .int32, .uint64, .int64]
        let tree = ChoiceTree.group((0 ..< 120).map { index in
            magnitudeLeaf(ZobristHash.mix(seed, at: index) % 120, tag: tags[index % tags.count])
        })
        let graph = stalledGraph(tree)
        let expected = eagerPairs(graph: graph)
        var cursor = RelationPairCursor(graph: graph)
        let actual = drain(&cursor)
        #expect(expected.count > GraphRedistributionEncoder.maxPairsPerScope)
        #expect(actual.map(signature) == expected.map(signature))
        #expect(RelationQuery.build(graph: graph)?.pairs.map(signature) == Array(expected.prefix(GraphRedistributionEncoder.maxPairsPerScope)).map(signature))
    }

    @Test("Reduced ratios preserve scale-one rejection and the cap boundary", arguments: [TypeTag.uint64, .int64])
    func ratioBoundaries(tag: TypeTag) {
        for numerator: UInt64 in 1 ... 17 {
            for denominator: UInt64 in 1 ... 17 {
                for scale: UInt64 in [1, 2, 100] {
                    let graph = stalledGraph(.group([
                        magnitudeLeaf(numerator * scale, tag: tag),
                        magnitudeLeaf(denominator * scale, tag: tag),
                    ]))
                    var cursor = RelationPairCursor(graph: graph)
                    #expect(drain(&cursor).map(signature) == eagerPairs(graph: graph).map(signature))
                }
            }
        }
    }

    @Test("Magnitude lookup multiplication remains exact near integer limits", arguments: [TypeTag.uint64, .int64])
    func integerBoundaries(tag: TypeTag) {
        let maximum = tag == .uint64 ? UInt64.max : UInt64(Int64.max)
        let graph = stalledGraph(.group([
            magnitudeLeaf(maximum, tag: tag),
            magnitudeLeaf(maximum / 3 * 2, tag: tag),
            magnitudeLeaf(maximum / 3, tag: tag),
            magnitudeLeaf(maximum - 1, tag: tag),
            magnitudeLeaf(maximum / 2, tag: tag),
            magnitudeLeaf(2, tag: tag),
            magnitudeLeaf(32, tag: tag),
        ]))
        var cursor = RelationPairCursor(graph: graph)
        let actual = drain(&cursor)
        let expected = eagerPairs(graph: graph)
        #expect(expected.isEmpty == false)
        #expect(actual.map(signature) == expected.map(signature))
    }

    @Test("The index retains convergence, control, type, sign, and reduction-target gates")
    func eligibilityGates() {
        let tree = ChoiceTree.group([
            magnitudeLeaf(200), magnitudeLeaf(100),
            magnitudeLeaf(40), magnitudeLeaf(20),
            magnitudeLeaf(80), magnitudeLeaf(60), magnitudeLeaf(50),
            .choice(ChoiceValue(UInt64(10), tag: .uint64), .init(validRange: 10 ... 20, isRangeExplicit: true)),
            .int64(-5),
            .choice(ChoiceValue(40.0, tag: .double), .init(validRange: nil)),
            magnitudeLeaf(0),
            magnitudeLeaf(100, tag: .uint16),
        ])
        var graph = stalledGraph(tree)
        let leaves = graph.leafNodes
        graph.convergenceStore.removeValue(forKey: leaves[2])
        graph.convergenceStore[leaves[3]] = ConvergedOrigin(bound: 21, signal: .monotoneConvergence, configuration: .binarySearchSemanticSimplest, cycle: 0)
        annotate(leaves[4], graph: &graph, annotation: .init(bindRole: .independent, controlKind: .depthControl))
        annotate(leaves[5], graph: &graph, annotation: .init(bindRole: .independent, controlKind: .laneControl))
        annotate(leaves[6], graph: &graph, annotation: .init(bindRole: .bindInner(controllingNodeID: 0, depth: 1), controlKind: .standard))
        var cursor = RelationPairCursor(graph: graph)
        let actual = drain(&cursor)
        #expect(cursor.preparedLeafCount == 3)
        #expect(actual.map(signature) == eagerPairs(graph: graph).map(signature))
        #expect(actual.count == 1)
        #expect(actual.first?.first.nodeID == leaves[0])
        #expect(actual.first?.second.nodeID == leaves[1])
    }

    @Test("Equal and unrelated wide magnitudes require only bounded lookups per leaf", arguments: [false, true])
    func wideSparseDiscovery(equalMagnitudes: Bool) {
        let count = 10000
        let graph = stalledGraph(.group((0 ..< count).map { index in
            magnitudeLeaf(equalMagnitudes ? 100 : UInt64(1_000_000 + index))
        }))
        var cursor = RelationPairCursor(graph: graph)
        #expect(cursor.preparedLeafCount == count)
        #expect(cursor.magnitudeLookupCount == 0)
        #expect(cursor.next(lastAccepted: false) == nil)
        #expect(cursor.magnitudeLookupCount > 0)
        #expect(cursor.magnitudeLookupCount <= count * Int(RelationQuery.ratioCap * (RelationQuery.ratioCap - 1)))
        let lookups = cursor.magnitudeLookupCount
        #expect(cursor.next(lastAccepted: false) == nil)
        #expect(cursor.magnitudeLookupCount == lookups)
    }

    @Test("Dense duplicate buckets stream only the requested positional prefix")
    func densePrefix() throws {
        let tree = ChoiceTree.group((0 ..< 1000).flatMap { _ in [magnitudeLeaf(200), magnitudeLeaf(100)] })
        let graph = stalledGraph(tree)
        var cursor = RelationPairCursor(graph: graph)
        var actual: [RelationPair] = []
        for _ in 0 ..< GraphRedistributionEncoder.maxPairsPerScope {
            let next = cursor.next(lastAccepted: false)
            try actual.append(#require(next))
        }
        #expect(actual.count == 30)
        #expect(actual.allSatisfy { $0.first.nodeID == graph.leafNodes[0] })
        #expect(actual.map { $0.second.nodeID } == stride(from: 1, to: 60, by: 2).map { graph.leafNodes[$0] })
        #expect(cursor.magnitudeLookupCount <= Int(RelationQuery.ratioCap * (RelationQuery.ratioCap - 1)))
        #expect(RelationQuery.build(graph: graph)?.pairs.map(signature) == actual.map(signature))
    }

    @Test("Cursor copies resume independently from a partially consumed bucket merge")
    func copiedCursors() throws {
        let graph = stalledGraph(.group([200, 100, 50, 300, 100, 20, 400].map { magnitudeLeaf($0) }))
        var original = RelationPairCursor(graph: graph)
        let first = original.next(lastAccepted: false)
        _ = try #require(first)
        var copied = original
        let copiedLookups = copied.magnitudeLookupCount
        let remaining = drain(&original)
        #expect(copied.magnitudeLookupCount == copiedLookups)
        let remainingCopy = drain(&copied)
        #expect(remainingCopy.map(signature) == remaining.map(signature))
        #expect(copied.magnitudeLookupCount == original.magnitudeLookupCount)
    }

    // MARK: - Helpers

    private func magnitudeLeaf(_ magnitude: UInt64, tag: TypeTag = .uint64) -> ChoiceTree {
        let zero = ChoiceValue(tag.makeConvertible(bitPattern64: 0), tag: tag).semanticSimplest.bitPattern64
        return .choice(ChoiceValue(tag.makeConvertible(bitPattern64: zero + magnitude), tag: tag), .init(validRange: nil))
    }

    private func stalledGraph(_ tree: ChoiceTree) -> ChoiceGraph {
        var graph = ChoiceGraph.build(from: tree)
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
                continue
            }
            graph.convergenceStore[nodeID] = ConvergedOrigin(bound: metadata.value.bitPattern64, signal: .monotoneConvergence, configuration: .binarySearchSemanticSimplest, cycle: 0)
        }
        return graph
    }

    private func annotate(_ nodeID: Int, graph: inout ChoiceGraph, annotation: ScopeAnnotation) {
        let node = graph.nodes[nodeID]
        graph.nodes[nodeID] = ChoiceGraphNode(id: node.id, kind: node.kind, positionRange: node.positionRange, children: node.children, parent: node.parent, choicePath: node.choicePath, scopeAnnotation: annotation)
    }

    /// Keeps the original all-pairs scan as an independent oracle for both gate semantics and exact ratio orientation.
    private func eagerPairs(graph: ChoiceGraph) -> [RelationPair] {
        let leaves = graph.liveNodeIDs.compactMap { nodeID -> (entry: LeafEntry, tag: TypeTag, position: Int, magnitude: UInt64)? in
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind,
                  node.scopeAnnotation.isDepthControl == false,
                  node.scopeAnnotation.isLaneControl == false,
                  node.scopeAnnotation.isBindInner == false,
                  metadata.typeTag.isFloatingPoint == false,
                  let range = node.positionRange,
                  metadata.value.bitPattern64 != metadata.value.reductionTarget(in: metadata.validRange),
                  metadata.value.bitPattern64 > metadata.value.semanticSimplest.bitPattern64,
                  graph.convergenceStore[nodeID]?.bound == metadata.value.bitPattern64
            else {
                return nil
            }
            return (LeafEntry(nodeID: nodeID, mayReshapeOnAcceptance: node.scopeAnnotation.isBindInner, bindDepth: node.scopeAnnotation.controllingBindDepth), metadata.typeTag, range.lowerBound, metadata.value.bitPattern64 - metadata.value.semanticSimplest.bitPattern64)
        }.sorted { $0.position < $1.position }
        var pairs: [RelationPair] = []
        for firstIndex in leaves.indices {
            for secondIndex in (firstIndex + 1) ..< leaves.count {
                let first = leaves[firstIndex]
                let second = leaves[secondIndex]
                guard first.tag == second.tag else {
                    continue
                }
                var scale = first.magnitude
                var remainder = second.magnitude
                while remainder != 0 {
                    (scale, remainder) = (remainder, scale % remainder)
                }
                guard scale >= 2 else {
                    continue
                }
                let numerator = first.magnitude / scale
                let denominator = second.magnitude / scale
                guard numerator != denominator, max(numerator, denominator) <= RelationQuery.ratioCap else {
                    continue
                }
                pairs.append(RelationPair(first: first.entry, second: second.entry, numerator: numerator, denominator: denominator, scale: scale))
            }
        }
        return pairs
    }

    private func signature(_ pair: RelationPair) -> PairSignature {
        PairSignature(first: pair.first.nodeID, second: pair.second.nodeID, firstMayReshape: pair.first.mayReshapeOnAcceptance, secondMayReshape: pair.second.mayReshapeOnAcceptance, firstBindDepth: pair.first.bindDepth, secondBindDepth: pair.second.bindDepth, numerator: pair.numerator, denominator: pair.denominator, scale: pair.scale)
    }

    private func drain(_ cursor: inout RelationPairCursor) -> [RelationPair] {
        var pairs: [RelationPair] = []
        while let pair = cursor.next(lastAccepted: false) {
            pairs.append(pair)
        }
        return pairs
    }
}

/// Compares every emitted pair field without adding test-only conformances to production scopes.
private struct PairSignature: Equatable {
    let first: Int
    let second: Int
    let firstMayReshape: Bool
    let secondMayReshape: Bool
    let firstBindDepth: Int?
    let secondBindDepth: Int?
    let numerator: UInt64
    let denominator: UInt64
    let scale: UInt64
}
