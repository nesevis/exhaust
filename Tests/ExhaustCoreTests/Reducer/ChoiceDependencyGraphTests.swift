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

        let fingerprint1 = StructuralFingerprint.from(ChoiceSequence(tree1), bindIndex: BindSpanIndex(from: ChoiceSequence(tree1)))
        let fingerprint2 = StructuralFingerprint.from(ChoiceSequence(tree2), bindIndex: BindSpanIndex(from: ChoiceSequence(tree2)))

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

        let fingerprint1 = StructuralFingerprint.from(ChoiceSequence(tree1), bindIndex: BindSpanIndex(from: ChoiceSequence(tree1)))
        let fingerprint2 = StructuralFingerprint.from(ChoiceSequence(tree2), bindIndex: BindSpanIndex(from: ChoiceSequence(tree2)))

        #expect(fingerprint1 != fingerprint2)
        #expect(fingerprint1.width < fingerprint2.width)
    }

    @Test("Same width, different bind depth distribution produces different fingerprints")
    func sameWidthDifferentBindDepth() {
        // Group: .group(true), .value, .value, .group(false) = 4 entries, all at depth 0
        let tree1 = ChoiceTree.group([
            .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
        ])

        // Bind: .bind(true), .value, .value, .bind(false) = 4 entries, bound value at depth 1
        let tree2 = ChoiceTree.bind(
            inner: .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            bound: .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        )

        let fingerprint1 = StructuralFingerprint.from(ChoiceSequence(tree1), bindIndex: BindSpanIndex(from: ChoiceSequence(tree1)))
        let fingerprint2 = StructuralFingerprint.from(ChoiceSequence(tree2), bindIndex: BindSpanIndex(from: ChoiceSequence(tree2)))

        #expect(fingerprint1.width == fingerprint2.width)
        #expect(fingerprint1 != fingerprint2)
        #expect(fingerprint1.depthHash != fingerprint2.depthHash)
    }

    @Test("Compensating depth sum produces different fingerprints with rolling hash")
    func compensatingDepthSumProducesDifferentFingerprint() {
        // Two sequences with same width and same total depth sum
        // but different per-position depth distributions.
        // Tree A: bind(inner=v1, bound=bind(inner=v2, bound=v3))
        //   Sequence: [bind(t), v1@d0, bind(t), v2@d1, v3@d2, bind(f), bind(f)]
        //   depths: v1=0, v2=1, v3=2 → sum=3
        // Tree B: bind(inner=bind(inner=v1, bound=v2), bound=v3)
        //   Sequence: [bind(t), bind(t), v1@d1, v2@d2, bind(f), v3@d1, bind(f)]
        //   depths: v1=1, v2=2, v3=1 → sum=4 (different sum, trivially caught)
        //
        // For a true compensating-sum scenario, we need matched sums.
        // Tree C: group([bind(inner=v1@d0, bound=v2@d1), v3@d0])
        //   depths: v1=0, v2=1, v3=0 → sum=1
        // Tree D: group([v1@d0, bind(inner=v2@d0, bound=v3@d1)])
        //   depths: v1=0, v2=0, v3=1 → sum=1
        // Same width, same depth sum, but depth-1 value is at different positions.

        let treeC = ChoiceTree.group([
            .bind(
                inner: .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                bound: .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
            ),
            .choice(.unsigned(3, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
        ])

        let treeD = ChoiceTree.group([
            .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            .bind(
                inner: .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
                bound: .choice(.unsigned(3, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
            ),
        ])

        let seqC = ChoiceSequence(treeC)
        let seqD = ChoiceSequence(treeD)
        let fingerprintC = StructuralFingerprint.from(seqC, bindIndex: BindSpanIndex(from: seqC))
        let fingerprintD = StructuralFingerprint.from(seqD, bindIndex: BindSpanIndex(from: seqD))

        // Same width (both group two children with a bind), same depth sum,
        // but different per-position depth distribution.
        #expect(fingerprintC.width == fingerprintD.width)
        #expect(fingerprintC != fingerprintD, "Rolling hash should distinguish compensating depth distributions")
    }

    // MARK: - Topological Levels

    @Test("Empty DAG has no levels")
    func emptyDAGHasNoLevels() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
        ])
        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)

        #expect(dag.topologicalLevels().isEmpty)
    }

    @Test("Single bind is one level")
    func singleBindIsOneLevel() {
        let tree = ChoiceTree.bind(
            inner: .choice(.unsigned(42, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            bound: .choice(.unsigned(7, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        )
        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)

        let levels = dag.topologicalLevels()
        #expect(levels.count == 1)
        #expect(levels[0] == [0])
    }

    @Test("Nested binds produce two levels — outer at level 0, inner at level 1")
    func nestedBindsProduceTwoLevels() {
        let valA = ChoiceTree.choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valB = ChoiceTree.choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valC = ChoiceTree.choice(.unsigned(30, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let innerBind = ChoiceTree.bind(inner: valB, bound: valC)
        let outerBind = ChoiceTree.bind(inner: valA, bound: innerBind)

        let sequence = ChoiceSequence(outerBind)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: outerBind, bindIndex: bindIndex)

        let levels = dag.topologicalLevels()
        #expect(levels.count == 2)

        let outerIdx = dag.nodes.firstIndex { $0.positionRange == 1 ... 1 }!
        let innerIdx = dag.nodes.firstIndex { $0.positionRange == 3 ... 3 }!
        #expect(levels[0].contains(outerIdx))
        #expect(levels[1].contains(innerIdx))
    }

    @Test("Independent binds share level 0")
    func independentBindsShareLevel() {
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

        let levels = dag.topologicalLevels()
        #expect(levels.count == 1)
        #expect(levels[0].count == 2)
    }

    @Test("Branch inside bind is at deeper level than the bind-inner")
    func branchInsideBindAtDeeperLevel() {
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

        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)

        let levels = dag.topologicalLevels()
        #expect(levels.count == 2)

        let bindInnerIdx = dag.nodes.firstIndex { $0.kind == .structural(.bindInner(regionIndex: 0)) }!
        let branchIdx = dag.nodes.firstIndex { $0.kind == .structural(.branchSelector) }!
        #expect(levels[0].contains(bindInnerIdx))
        #expect(levels[1].contains(branchIdx))
    }

    @Test("Chain of three nested binds produces three levels")
    func levelCountMatchesChainDepth() {
        let val = ChoiceTree.choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let innermost = ChoiceTree.bind(inner: val, bound: val)
        let middle = ChoiceTree.bind(inner: val, bound: innermost)
        let outermost = ChoiceTree.bind(inner: val, bound: middle)

        let sequence = ChoiceSequence(outermost)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: outermost, bindIndex: bindIndex)

        let levels = dag.topologicalLevels()
        #expect(levels.count == 3)
        #expect(levels[0].count == 1)
        #expect(levels[1].count == 1)
        #expect(levels[2].count == 1)
    }

    @Test("All nodes appear exactly once across levels")
    func allNodesAppearExactlyOnce() {
        let val = ChoiceTree.choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let innermost = ChoiceTree.bind(inner: val, bound: val)
        let middle = ChoiceTree.bind(inner: val, bound: innermost)
        let outermost = ChoiceTree.bind(inner: val, bound: middle)

        let sequence = ChoiceSequence(outermost)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: outermost, bindIndex: bindIndex)

        let levels = dag.topologicalLevels()
        let allIndices = levels.flatMap { $0 }
        #expect(allIndices.count == dag.nodes.count)
        #expect(Set(allIndices).count == dag.nodes.count)
    }

    @Test("Parent-before-child invariant holds for all nodes")
    func parentBeforeChildInvariant() {
        // Use the branch-inside-bind fixture (has a dependency edge).
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

        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)

        let levels = dag.topologicalLevels()

        // Build node-to-level map.
        var nodeToLevel = [Int: Int]()
        for (levelIndex, nodesAtLevel) in levels.enumerated() {
            for nodeIndex in nodesAtLevel {
                nodeToLevel[nodeIndex] = levelIndex
            }
        }

        // For every dependent, the parent must be at a strictly lower level.
        for (nodeIndex, node) in dag.nodes.enumerated() {
            for dependent in node.dependents {
                #expect(
                    nodeToLevel[nodeIndex]! < nodeToLevel[dependent]!,
                    "Node \(nodeIndex) at level \(nodeToLevel[nodeIndex]!) has dependent \(dependent) at level \(nodeToLevel[dependent]!) — parent must be at a lower level"
                )
            }
        }
    }

    // MARK: - Node Bind Depth

    @Test("Bind-inner node bindDepth matches BindSpanIndex")
    func bindInnerDepthMatchesBindSpanIndex() {
        let valA = ChoiceTree.choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valB = ChoiceTree.choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valC = ChoiceTree.choice(.unsigned(30, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let innerBind = ChoiceTree.bind(inner: valB, bound: valC)
        let outerBind = ChoiceTree.bind(inner: valA, bound: innerBind)

        let sequence = ChoiceSequence(outerBind)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: outerBind, bindIndex: bindIndex)

        for node in dag.nodes {
            if case .structural(.bindInner) = node.kind {
                let expected = bindIndex.bindDepth(at: node.positionRange.lowerBound)
                #expect(node.bindDepth == expected)
            }
        }
    }

    @Test("Branch-selector node bindDepth is nil")
    func branchSelectorBindDepthIsNil() {
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

        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)

        let branchNode = dag.nodes.first { $0.kind == .structural(.branchSelector) }!
        #expect(branchNode.bindDepth == nil)
    }

    @Test("Nested bind depth increases — outer at 0, inner at 1")
    func nestedBindDepthIncreases() {
        let valA = ChoiceTree.choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valB = ChoiceTree.choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valC = ChoiceTree.choice(.unsigned(30, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let innerBind = ChoiceTree.bind(inner: valB, bound: valC)
        let outerBind = ChoiceTree.bind(inner: valA, bound: innerBind)

        let sequence = ChoiceSequence(outerBind)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: outerBind, bindIndex: bindIndex)

        let outerNode = dag.nodes.first { $0.positionRange == 1 ... 1 }!
        let innerNode = dag.nodes.first { $0.positionRange == 3 ... 3 }!
        #expect(outerNode.bindDepth == 0)
        #expect(innerNode.bindDepth == 1)
    }

    // MARK: - Structural Constancy Classification

    @Test("Range-controlling bind (no nested binds or picks) is structurally constant")
    func rangeControllingBindIsConstant() {
        let inner = ChoiceTree.choice(.unsigned(5, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let bound = ChoiceTree.group([
            .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let tree = ChoiceTree.bind(inner: inner, bound: bound)

        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)

        #expect(dag.nodes[0].isStructurallyConstant)
    }

    @Test("Structure-controlling bind (nested bind in bound) is not structurally constant")
    func structureControllingBindIsNotConstant() {
        let inner = ChoiceTree.choice(.unsigned(5, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let nestedBind = ChoiceTree.bind(
            inner: .choice(.unsigned(3, .uint64), .init(validRange: 0 ... 5, isRangeExplicit: true)),
            bound: .choice(.unsigned(7, .uint64), .init(validRange: 0 ... 50, isRangeExplicit: true))
        )
        let tree = ChoiceTree.bind(inner: inner, bound: nestedBind)

        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)

        let outerNode = dag.nodes.first { $0.positionRange == 1 ... 1 }!
        #expect(outerNode.isStructurallyConstant == false)
    }

    // MARK: - Calculator CDG Smoke Test

    @Test("Calculator-style CDG has bind-inner at level 0, nested branches at levels 1 and 2")
    func calculatorCDGLevelStructure() {
        // Simulates: bind(depth, bound: group([branch(div, [leaf, branch(add, [leaf, leaf])])]))
        // Structure: bind-inner controls depth, outer oneOf picks div, inner oneOf picks add.
        let leaf1 = ChoiceTree.choice(.unsigned(0, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let leaf2 = ChoiceTree.choice(.unsigned(6, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let leaf3 = ChoiceTree.choice(.unsigned(6, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))

        // Inner branch: add(leaf2, leaf3) — the selected branch
        let innerBranchA = ChoiceTree.branch(
            siteID: 1, weight: 1, id: 0, branchIDs: [0, 1],
            choice: leaf2
        )
        let innerBranchB = ChoiceTree.branch(
            siteID: 1, weight: 1, id: 1, branchIDs: [0, 1],
            choice: leaf3
        )
        let innerPick = ChoiceTree.group([innerBranchA, .selected(innerBranchB)])

        // Outer branch: div(leaf1, innerPick) — the selected branch
        let outerBranchA = ChoiceTree.branch(
            siteID: 0, weight: 1, id: 0, branchIDs: [0, 1],
            choice: leaf1
        )
        let outerBranchB = ChoiceTree.branch(
            siteID: 0, weight: 1, id: 1, branchIDs: [0, 1],
            choice: ChoiceTree.group([leaf1, innerPick])
        )
        let outerPick = ChoiceTree.group([outerBranchA, .selected(outerBranchB)])

        // Top-level bind: bind(depthValue, bound: outerPick)
        let depthValue = ChoiceTree.choice(.unsigned(2, .uint64), .init(validRange: 0 ... 5, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: depthValue, bound: outerPick)

        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)

        // Should have: 1 bind-inner + 2 branch-selectors = 3 nodes.
        #expect(dag.nodes.count == 3)

        let levels = dag.topologicalLevels()
        #expect(levels.count == 3)

        // Bind-inner at level 0.
        let bindInnerIdx = dag.nodes.firstIndex { $0.kind == .structural(.bindInner(regionIndex: 0)) }!
        #expect(levels[0].contains(bindInnerIdx))
        #expect(dag.nodes[bindInnerIdx].bindDepth == 0)

        // Both branch-selectors at levels 1 and 2.
        let branchIndices = dag.nodes.indices.filter { dag.nodes[$0].kind == .structural(.branchSelector) }
        #expect(branchIndices.count == 2)
        for branchIdx in branchIndices {
            #expect(dag.nodes[branchIdx].bindDepth == nil)
        }

        // One branch at level 1 (outer), one at level 2 (inner).
        let branchLevels = branchIndices.map { idx in
            levels.firstIndex { $0.contains(idx) }!
        }.sorted()
        #expect(branchLevels == [1, 2])

        // Edges: bind-inner → outer branch (overlap), outer branch → inner branch (containment).
        #expect(dag.nodes[bindInnerIdx].dependents.count >= 1)
        let outerBranchIdx = branchIndices.first { levels[1].contains($0) }!
        let innerBranchIdx = branchIndices.first { levels[2].contains($0) }!
        #expect(dag.nodes[bindInnerIdx].dependents.contains(outerBranchIdx))
        #expect(dag.nodes[outerBranchIdx].dependents.contains(innerBranchIdx))
    }
}
