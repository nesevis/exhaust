//
//  ChoiceDependencyGraphTests.swift
//  Exhaust
//

import ExhaustCore
import Testing

// MARK: - ChoiceDependencyGraph Structure Tests

@Suite("ChoiceDependencyGraph")
struct ChoiceDependencyGraphTests {
    // MARK: - 0a: DAG Structure

    @Test("No binds, no branches — all positions are leaves")
    func noBindsNoBranches() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
        ])
        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)

        #expect(dag.nodes.isEmpty)
        #expect(dag.topologicalOrder.isEmpty)
        // Positions 1 and 2 are values, not inside any structural node.
        #expect(dag.leafPositions == [1 ... 2])
    }

    @Test("Single bind produces one structural node and one leaf")
    func singleBind() {
        let inner = ChoiceTree.choice(.unsigned(42, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let bound = ChoiceTree.choice(.unsigned(7, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: inner, bound: bound)

        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)

        #expect(dag.nodes.count == 1)
        #expect(dag.nodes[0].kind == .structural(.bindInner(regionIndex: 0)))
        #expect(dag.nodes[0].positionRange == 1 ... 1)
        #expect(dag.nodes[0].dependents.isEmpty)
        #expect(dag.topologicalOrder == [0])
        // Position 2 (bound value) is a leaf.
        #expect(dag.leafPositions == [2 ... 2])
    }

    @Test("Nested binds produce two structural nodes with edge from outer to inner")
    func nestedBinds() {
        let valA = ChoiceTree.choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valB = ChoiceTree.choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valC = ChoiceTree.choice(.unsigned(30, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let innerBind = ChoiceTree.bind(inner: valB, bound: valC)
        let outerBind = ChoiceTree.bind(inner: valA, bound: innerBind)

        // Flattened: .bind(true)[0], .value(10)[1], .bind(true)[2], .value(20)[3], .value(30)[4], .bind(false)[5], .bind(false)[6]
        let sequence = ChoiceSequence(outerBind)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: outerBind, bindIndex: bindIndex)

        #expect(dag.nodes.count == 2)

        // Outer bind-inner at position 1, inner bind-inner at position 3.
        let outerNode = dag.nodes.first { $0.positionRange == 1 ... 1 }
        let innerNode = dag.nodes.first { $0.positionRange == 3 ... 3 }
        #expect(outerNode != nil)
        #expect(innerNode != nil)

        // Outer has inner as dependent (inner's positionRange 3...3 overlaps outer's scope 2...5).
        let outerIdx = dag.nodes.firstIndex { $0.positionRange == 1 ... 1 }!
        let innerIdx = dag.nodes.firstIndex { $0.positionRange == 3 ... 3 }!
        #expect(dag.nodes[outerIdx].dependents.contains(innerIdx))
        #expect(dag.nodes[innerIdx].dependents.contains(outerIdx) == false)

        // Topological order: outer before inner.
        let outerOrder = dag.topologicalOrder.firstIndex(of: outerIdx)!
        let innerOrder = dag.topologicalOrder.firstIndex(of: innerIdx)!
        #expect(outerOrder < innerOrder)

        // Leaf: position 4 (value(30)).
        #expect(dag.leafPositions == [4 ... 4])
    }

    @Test("Independent binds produce two unconnected structural nodes")
    func independentBinds() {
        let bind1 = ChoiceTree.bind(
            inner: .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            bound: .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        )
        let bind2 = ChoiceTree.bind(
            inner: .choice(.unsigned(3, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            bound: .choice(.unsigned(4, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        )
        let tree = ChoiceTree.group([bind1, bind2])

        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)

        #expect(dag.nodes.count == 2)
        #expect(dag.nodes[0].dependents.isEmpty)
        #expect(dag.nodes[1].dependents.isEmpty)
        #expect(dag.topologicalOrder.count == 2)

        // Leaf positions: the two bound values.
        #expect(dag.leafPositions.count == 2)
    }

    @Test("Branch inside bind creates edge from bind-inner to branch selector")
    func branchInsideBind() {
        let branchA = ChoiceTree.branch(
            siteID: 0, weight: 1, id: 0, branchIDs: [0, 1],
            choice: .choice(.unsigned(100, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        )
        let branchB = ChoiceTree.branch(
            siteID: 0, weight: 1, id: 1, branchIDs: [0, 1],
            choice: .choice(.unsigned(200, .uint64), .init(validRange: 0 ... 200, isRangeExplicit: true))
        )
        let pickSite = ChoiceTree.group([branchA, .selected(branchB)])
        let inner = ChoiceTree.choice(.unsigned(5, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: inner, bound: pickSite)

        // Flattened: .bind(true)[0], .value(5)[1], .group(true)[2], .branch(...)[3], .value(200)[4], .group(false)[5], .bind(false)[6]
        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)

        #expect(dag.nodes.count == 2)

        let bindInnerIdx = dag.nodes.firstIndex { $0.kind == .structural(.bindInner(regionIndex: 0)) }!
        let branchIdx = dag.nodes.firstIndex { $0.kind == .structural(.branchSelector) }!

        #expect(dag.nodes[bindInnerIdx].positionRange == 1 ... 1)
        #expect(dag.nodes[branchIdx].positionRange == 3 ... 3)

        // Bind-inner's scope (bound range 2...5) contains branch at 3 → edge.
        #expect(dag.nodes[bindInnerIdx].dependents.contains(branchIdx))
        #expect(dag.nodes[branchIdx].dependents.contains(bindInnerIdx) == false)

        // Topological order: bind-inner before branch.
        let bindOrder = dag.topologicalOrder.firstIndex(of: bindInnerIdx)!
        let branchOrder = dag.topologicalOrder.firstIndex(of: branchIdx)!
        #expect(bindOrder < branchOrder)

        // Leaf: position 4.
        #expect(dag.leafPositions == [4 ... 4])
    }

    @Test("Branch at top level produces one structural node")
    func branchAtTopLevel() {
        let branchA = ChoiceTree.branch(
            siteID: 0, weight: 1, id: 0, branchIDs: [0, 1],
            choice: .choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        )
        let branchB = ChoiceTree.branch(
            siteID: 0, weight: 1, id: 1, branchIDs: [0, 1],
            choice: .choice(.unsigned(20, .uint64), .init(validRange: 0 ... 200, isRangeExplicit: true))
        )
        let tree = ChoiceTree.group([branchA, .selected(branchB)])

        // Flattened: .group(true)[0], .branch(...)[1], .value(20)[2], .group(false)[3]
        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)

        #expect(dag.nodes.count == 1)
        #expect(dag.nodes[0].kind == .structural(.branchSelector))
        #expect(dag.nodes[0].positionRange == 1 ... 1)
        #expect(dag.nodes[0].dependents.isEmpty)
        #expect(dag.topologicalOrder == [0])
        #expect(dag.leafPositions == [2 ... 2])
    }

    @Test("getSize-bind is transparent and produces no structural nodes")
    func getSizeBindTransparent() {
        let getSizeInner = ChoiceTree.getSize(10)
        let bound = ChoiceTree.choice(.unsigned(42, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: getSizeInner, bound: bound)

        // getSize-bind flattens as group, not bind: .group(true)[0], .value(42)[1], .group(false)[2]
        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)

        #expect(dag.nodes.isEmpty)
        #expect(dag.topologicalOrder.isEmpty)
        #expect(dag.leafPositions == [1 ... 1])
    }

    // MARK: - 0b: Structural Constancy

    @Test("Bind with no nested binds in bound subtree is structurally constant")
    func structurallyConstantBind() {
        let inner = ChoiceTree.choice(.unsigned(5, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let bound = ChoiceTree.group([
            .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let tree = ChoiceTree.bind(inner: inner, bound: bound)

        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)

        #expect(dag.nodes.count == 1)
        #expect(dag.nodes[0].isStructurallyConstant)
    }

    @Test("Bind with nested bind in bound subtree is structurally dependent")
    func structurallyDependentBind() {
        let inner = ChoiceTree.choice(.unsigned(5, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let nestedBind = ChoiceTree.bind(
            inner: .choice(.unsigned(3, .uint64), .init(validRange: 0 ... 5, isRangeExplicit: true)),
            bound: .choice(.unsigned(7, .uint64), .init(validRange: 0 ... 50, isRangeExplicit: true))
        )
        let tree = ChoiceTree.bind(inner: inner, bound: nestedBind)

        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)

        // Outer bind-inner node should NOT be structurally constant.
        let outerNode = dag.nodes.first { $0.positionRange == 1 ... 1 }
        #expect(outerNode != nil)
        #expect(outerNode!.isStructurallyConstant == false)
    }

    @Test("Bind with picks but no nested bind in bound subtree is structurally dependent")
    func structurallyDependentDueToPicks() {
        let inner = ChoiceTree.choice(.unsigned(5, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        // Bound subtree contains a pick site but no nested bind.
        let branch = ChoiceTree.branch(
            siteID: 0,
            weight: 1,
            id: 0,
            branchIDs: [0, 1],
            choice: .choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        )
        let bound = ChoiceTree.group([branch, .selected(branch)])
        let tree = ChoiceTree.bind(inner: inner, bound: bound)

        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)

        #expect(dag.nodes.count == 2) // bind-inner + branch selector
        let bindNode = dag.nodes.first { $0.positionRange == 1 ... 1 }
        #expect(bindNode != nil)
        #expect(bindNode!.isStructurallyConstant == false)
    }

    // MARK: - 0c: StructuralFingerprint

    @Test("Trees with same width and bind depth produce equal fingerprints")
    func equalFingerprints() {
        let tree1 = ChoiceTree.group([
            .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
        ])
        let tree2 = ChoiceTree.group([
            .choice(.unsigned(5, .uint64), .init(validRange: 0 ... 20, isRangeExplicit: true)),
            .choice(.unsigned(6, .uint64), .init(validRange: 0 ... 20, isRangeExplicit: true)),
        ])

        let fingerprint1 = StructuralFingerprint.from(tree1, bindIndex: BindSpanIndex(from: ChoiceSequence(tree1)))
        let fingerprint2 = StructuralFingerprint.from(tree2, bindIndex: BindSpanIndex(from: ChoiceSequence(tree2)))

        #expect(fingerprint1 == fingerprint2)
    }

    @Test("Trees with different widths produce different fingerprints")
    func differentWidth() {
        let tree1 = ChoiceTree.group([
            .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
        ])
        let tree2 = ChoiceTree.group([
            .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
        ])

        let fingerprint1 = StructuralFingerprint.from(tree1, bindIndex: BindSpanIndex(from: ChoiceSequence(tree1)))
        let fingerprint2 = StructuralFingerprint.from(tree2, bindIndex: BindSpanIndex(from: ChoiceSequence(tree2)))

        #expect(fingerprint1 != fingerprint2)
        #expect(fingerprint1.width < fingerprint2.width)
    }

    @Test("Same width, different bind depth sum produces different fingerprints")
    func sameWidthDifferentBindDepth() {
        // Group: .group(true), .value, .value, .group(false) = 4 entries, depth sum 0
        let tree1 = ChoiceTree.group([
            .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
        ])

        // Bind: .bind(true), .value, .value, .bind(false) = 4 entries, depth sum > 0
        let tree2 = ChoiceTree.bind(
            inner: .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            bound: .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        )

        let fingerprint1 = StructuralFingerprint.from(tree1, bindIndex: BindSpanIndex(from: ChoiceSequence(tree1)))
        let fingerprint2 = StructuralFingerprint.from(tree2, bindIndex: BindSpanIndex(from: ChoiceSequence(tree2)))

        #expect(fingerprint1.width == fingerprint2.width)
        #expect(fingerprint1 != fingerprint2)
        #expect(fingerprint1.bindDepthSum == 0)
        #expect(fingerprint2.bindDepthSum == 1)
    }
}
