//
//  ChoiceGraphClassificationTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

// MARK: - Bind Classification

@Suite("ChoiceGraph Bind Classification")
struct ChoiceGraphClassificationTests {
    // MARK: - Coupling-like (identical topology)

    @Test("Coupling-shaped bind classifies as identical + both")
    func couplingShapedBindIsIdentical() throws {
        // `int(in: 0...5).bound { n in arrayOf(int(in: 0...max(0, n)), exactly: UInt64(max(2, n + 1))) }`.
        // Upstream variation shifts leaf validRanges and the sequence length, but the
        // bound subtree stays a homogeneous sequence of int chooseBits nodes. Identical
        // topology, both endpoints liftable.
        let gen = makeCouplingLikeGen()
        let tree = try generateTree(from: gen, seed: 17)
        var graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let bindNodeID = try #require(firstActiveBindNodeID(in: graph))
        let upstreamLeafNodeID = try #require(innerLeafNodeID(ofBind: bindNodeID, in: graph))

        graph.classifyBind(
            at: bindNodeID,
            gen: gen.erase(),
            baseSequence: sequence,
            fallbackTree: tree,
            upstreamLeafNodeID: upstreamLeafNodeID
        )

        let classification = try #require(bindClassification(at: bindNodeID, in: graph))
        #expect(classification.topology == .identical)
        #expect(classification.liftability == .both)
    }

    // MARK: - Calculator-like (divergent topology)

    @Test("Shape-divergent bind classifies as divergent")
    func shapeDivergentBindIsDivergent() throws {
        // Low endpoint produces a single chooseBits leaf; high endpoint produces a
        // bind-wrapped sequence of chooseBits leaves. Different node kinds at the root
        // of the bound subtree → divergent topology.
        let gen = makeDivergentGen()
        let tree = try generateTree(from: gen, seed: 33)
        var graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let bindNodeID = try #require(firstActiveBindNodeID(in: graph))
        let upstreamLeafNodeID = try #require(innerLeafNodeID(ofBind: bindNodeID, in: graph))

        graph.classifyBind(
            at: bindNodeID,
            gen: gen.erase(),
            baseSequence: sequence,
            fallbackTree: tree,
            upstreamLeafNodeID: upstreamLeafNodeID
        )

        let classification = try #require(bindClassification(at: bindNodeID, in: graph))
        #expect(classification.topology == .divergent)
        #expect(classification.liftability == .both)
    }

    // MARK: - Singleton upstream

    @Test("Singleton upstream classifies as unclassifiable + both")
    func singletonUpstreamIsUnclassifiable() throws {
        // int(in: 7...7) — lowerBound == upperBound after clamping, no comparison possible.
        let gen: Generator<Int> = Gen.choose(in: 7 ... 7 as ClosedRange<Int>)._bound(
            forward: { _ in Gen.choose(in: 0 ... 3 as ClosedRange<Int>) },
            backward: { m in max(7, min(7, m)) }
        )
        let tree = try generateTree(from: gen, seed: 5)
        var graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let bindNodeID = try #require(firstActiveBindNodeID(in: graph))
        let upstreamLeafNodeID = try #require(innerLeafNodeID(ofBind: bindNodeID, in: graph))

        graph.classifyBind(
            at: bindNodeID,
            gen: gen.erase(),
            baseSequence: sequence,
            fallbackTree: tree,
            upstreamLeafNodeID: upstreamLeafNodeID
        )

        let classification = try #require(bindClassification(at: bindNodeID, in: graph))
        #expect(classification.topology == .unclassifiable)
        #expect(classification.liftability == .both)
    }

    // MARK: - Idempotency

    @Test("Second classifyBind call is a no-op")
    func classifyBindIsIdempotent() throws {
        let gen = makeCouplingLikeGen()
        let tree = try generateTree(from: gen, seed: 9)
        var graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let bindNodeID = try #require(firstActiveBindNodeID(in: graph))
        let upstreamLeafNodeID = try #require(innerLeafNodeID(ofBind: bindNodeID, in: graph))

        graph.classifyBind(
            at: bindNodeID,
            gen: gen.erase(),
            baseSequence: sequence,
            fallbackTree: tree,
            upstreamLeafNodeID: upstreamLeafNodeID
        )
        let firstClassification = try #require(bindClassification(at: bindNodeID, in: graph))

        graph.classifyBind(
            at: bindNodeID,
            gen: gen.erase(),
            baseSequence: sequence,
            fallbackTree: tree,
            upstreamLeafNodeID: upstreamLeafNodeID
        )
        let secondClassification = try #require(bindClassification(at: bindNodeID, in: graph))

        #expect(firstClassification == secondClassification)
    }

    // MARK: - Reshape clears classification

    @Test("Applying a bind-inner reshape signals full rebuild")
    func bindReshapeSignalsRebuild() throws {
        let gen = makeCouplingLikeGen()
        let tree = try generateTree(from: gen, seed: 12)
        var graph = ChoiceGraph.build(from: tree)
        let bindNodeID = try #require(firstActiveBindNodeID(in: graph))
        let upstreamLeafNodeID = try #require(innerLeafNodeID(ofBind: bindNodeID, in: graph))

        let currentLeafMetadata = try #require(chooseBitsMetadata(ofNodeID: upstreamLeafNodeID, in: graph))
        let shiftedBitPattern: UInt64 = currentLeafMetadata.value.bitPattern64 == 0 ? 3 : 0
        let shiftedChoice = ChoiceValue(
            currentLeafMetadata.typeTag.makeConvertible(bitPattern64: shiftedBitPattern),
            tag: currentLeafMetadata.typeTag
        )
        let reshapeChange = LeafChange(
            leafNodeID: upstreamLeafNodeID,
            newValue: shiftedChoice,
            mayReshape: true
        )
        let application = graph.apply(.leafValues([reshapeChange]))

        #expect(application.requiresFullRebuild)
    }

    // MARK: - Topology Walker (pure)

    @Test("sameTopology: identical leaf trees match regardless of value")
    func sameTopologyLeaves() {
        let a = ChoiceTree.choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let b = ChoiceTree.choice(ChoiceValue(5 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        #expect(ChoiceGraph.sameTopology(a, b))
    }

    @Test("sameTopology: sequence element-count delta is not divergence")
    func sameTopologyVariableLengthSequence() {
        let elements2: [ChoiceTree] = (0 ..< 2).map { _ in
            ChoiceTree.choice(ChoiceValue(0 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        }
        let elements5: [ChoiceTree] = (0 ..< 5).map { _ in
            ChoiceTree.choice(ChoiceValue(0 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        }
        let seqLow = ChoiceTree.sequence(elements: elements2, metadata: .init(validRange: nil, isRangeExplicit: false))
        let seqHigh = ChoiceTree.sequence(elements: elements5, metadata: .init(validRange: nil, isRangeExplicit: false))
        #expect(ChoiceGraph.sameTopology(seqLow, seqHigh))
    }

    @Test("sameTopology: leaf on one side, sequence on the other is divergent")
    func sameTopologyKindMismatch() {
        let leaf = ChoiceTree.choice(ChoiceValue(0 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let seq = ChoiceTree.sequence(
            elements: [leaf],
            metadata: .init(validRange: nil, isRangeExplicit: false)
        )
        #expect(ChoiceGraph.sameTopology(leaf, seq) == false)
    }
}

// MARK: - Fixtures

private func makeCouplingLikeGen() -> Generator<[Int]> {
    Gen.choose(in: 0 ... 5 as ClosedRange<Int>)._bound(
        forward: { n in
            Gen.arrayOf(
                Gen.choose(in: 0 ... max(0, n) as ClosedRange<Int>),
                exactly: UInt64(max(2, n + 1))
            )
        },
        backward: { arr in
            max(0, min(5, arr.count - 2))
        }
    )
}

private func makeDivergentGen() -> Generator<Int> {
    // Low endpoint → int(in: 0...3) (a single chooseBits leaf).
    // High endpoint → an array(int) summed back to an Int (a sequence under a
    // transform-bind). Different kinds at the root of the bound subtree.
    Gen.choose(in: 0 ... 5 as ClosedRange<Int>)._bound(
        forward: { n -> Generator<Int> in
            if n <= 1 {
                return Gen.choose(in: 0 ... 3 as ClosedRange<Int>)
            }
            return Gen.arrayOf(Gen.choose(in: 0 ... 3 as ClosedRange<Int>), exactly: UInt64(n)).map { $0.reduce(0, +) }
        },
        backward: { _ in 3 }
    )
}

private func generateTree(
    from gen: Generator<some Any>,
    seed: UInt64
) throws -> ChoiceTree {
    var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed)
    let (_, tree) = try #require(try iterator.next())
    return tree
}

private func firstActiveBindNodeID(in graph: ChoiceGraph) -> Int? {
    for node in graph.nodes {
        guard case .bind = node.kind else { continue }
        guard node.positionRange != nil else { continue }
        return node.id
    }
    return nil
}

private func innerLeafNodeID(ofBind bindNodeID: Int, in graph: ChoiceGraph) -> Int? {
    guard case let .bind(metadata) = graph.nodes[bindNodeID].kind else { return nil }
    guard graph.nodes[bindNodeID].children.count > metadata.innerChildIndex else { return nil }
    let innerChildID = graph.nodes[bindNodeID].children[metadata.innerChildIndex]
    guard case .chooseBits = graph.nodes[innerChildID].kind else { return nil }
    return innerChildID
}

private func bindClassification(at bindNodeID: Int, in graph: ChoiceGraph) -> BindClassification? {
    guard case let .bind(metadata) = graph.nodes[bindNodeID].kind else { return nil }
    return metadata.classification
}

private func chooseBitsMetadata(ofNodeID nodeID: Int, in graph: ChoiceGraph) -> ChooseBitsMetadata? {
    guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { return nil }
    return metadata
}
