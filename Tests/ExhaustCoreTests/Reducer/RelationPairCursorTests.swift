import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Indexed relation pair discovery")
struct RelationPairCursorTests {
    @Test("Reduced ratios preserve scale-one rejection and the cap boundary", arguments: [TypeTag.uint64, .int64])
    func ratioBoundaries(tag: TypeTag) {
        for numerator: UInt64 in 1 ... 17 {
            for denominator: UInt64 in 1 ... 17 {
                for scale: UInt64 in [1, 2, 100] {
                    let graph = ChoiceGraph.stalled(from: .group([
                        magnitudeLeaf(numerator * scale, tag: tag),
                        magnitudeLeaf(denominator * scale, tag: tag),
                    ]))
                    var cursor = RelationPairCursor(graph: graph)
                    #expect(drain(&cursor).map(signature) == EagerExchangeReference.relationPairs(graph: graph).map(signature))
                }
            }
        }
    }

    @Test("Magnitude lookup multiplication remains exact near integer limits", arguments: [TypeTag.uint64, .int64])
    func integerBoundaries(tag: TypeTag) {
        let maximum = tag == .uint64 ? UInt64.max : UInt64(Int64.max)
        let graph = ChoiceGraph.stalled(from: .group([
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
        let expected = EagerExchangeReference.relationPairs(graph: graph)
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
        var graph = ChoiceGraph.stalled(from: tree)
        let leaves = graph.leafNodes
        graph.convergenceStore.removeValue(forKey: leaves[2])
        graph.convergenceStore[leaves[3]] = ConvergedOrigin(bound: 21, signal: .monotoneConvergence, configuration: .binarySearchSemanticSimplest, cycle: 0)
        annotate(leaves[4], graph: &graph, annotation: .init(bindRole: .independent, controlKind: .depthControl))
        annotate(leaves[5], graph: &graph, annotation: .init(bindRole: .independent, controlKind: .laneControl))
        annotate(leaves[6], graph: &graph, annotation: .init(bindRole: .bindInner(controllingNodeID: 0, depth: 1), controlKind: .standard))
        var cursor = RelationPairCursor(graph: graph)
        let actual = drain(&cursor)
        #expect(cursor.preparedLeafCount == 3)
        #expect(actual.map(signature) == EagerExchangeReference.relationPairs(graph: graph).map(signature))
        #expect(actual.count == 1)
        #expect(actual.first?.first.nodeID == leaves[0])
        #expect(actual.first?.second.nodeID == leaves[1])
    }

    @Test("Equal and unrelated wide magnitudes require only bounded lookups per leaf", arguments: [false, true])
    func wideSparseDiscovery(equalMagnitudes: Bool) {
        let count = 10000
        let graph = ChoiceGraph.stalled(from: .group((0 ..< count).map { index in
            magnitudeLeaf(equalMagnitudes ? 100 : UInt64(1_000_000 + index))
        }))
        var cursor = RelationPairCursor(graph: graph)
        #expect(cursor.preparedLeafCount == count)
        #expect(cursor.magnitudeLookupCount == 0)
        #expect(cursor.next() == nil)
        #expect(cursor.magnitudeLookupCount > 0)
        #expect(cursor.magnitudeLookupCount <= count * Int(RelationQuery.ratioCap * (RelationQuery.ratioCap - 1)))
        let lookups = cursor.magnitudeLookupCount
        #expect(cursor.next() == nil)
        #expect(cursor.magnitudeLookupCount == lookups)
    }

    @Test("Dense duplicate buckets stream only the requested positional prefix")
    func densePrefix() throws {
        let tree = ChoiceTree.group((0 ..< 1000).flatMap { _ in [magnitudeLeaf(200), magnitudeLeaf(100)] })
        let graph = ChoiceGraph.stalled(from: tree)
        var cursor = RelationPairCursor(graph: graph)
        var actual: [RelationPair] = []
        for _ in 0 ..< GraphRedistributionEncoder.maxPairsPerScope {
            let next = cursor.next()
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
        let graph = ChoiceGraph.stalled(from: .group([200, 100, 50, 300, 100, 20, 400].map { magnitudeLeaf($0) }))
        var original = RelationPairCursor(graph: graph)
        let first = original.next()
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

    private func annotate(_ nodeID: Int, graph: inout ChoiceGraph, annotation: ScopeAnnotation) {
        let node = graph.nodes[nodeID]
        graph.nodes[nodeID] = ChoiceGraphNode(id: node.id, kind: node.kind, positionRange: node.positionRange, children: node.children, parent: node.parent, choicePath: node.choicePath, scopeAnnotation: annotation)
    }

    private func signature(_ pair: RelationPair) -> PairSignature {
        PairSignature(first: pair.first.nodeID, second: pair.second.nodeID, firstMayReshape: pair.first.mayReshapeOnAcceptance, secondMayReshape: pair.second.mayReshapeOnAcceptance, firstBindDepth: pair.first.bindDepth, secondBindDepth: pair.second.bindDepth, numerator: pair.numerator, denominator: pair.denominator, scale: pair.scale)
    }

    private func drain(_ cursor: inout RelationPairCursor) -> [RelationPair] {
        var pairs: [RelationPair] = []
        while let pair = cursor.next() {
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
