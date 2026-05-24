//
//  ChoiceGraphTests.swift
//  Exhaust
//

import ExhaustCore
import Testing

// MARK: - ChoiceGraph Construction Tests

@Suite("ChoiceGraph")
struct ChoiceGraphTests {
    // MARK: - Node Type Tests

    @Test("Zip of chooseBits leaves — two leaf nodes under one zip")
    func zipOfLeaves() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)

        // One zip node + two chooseBits leaves.
        #expect(graph.nodes.count == 3)

        let zipNodes = graph.nodes.filter {
            if case .zip = $0.kind { return true }
            return false
        }
        #expect(zipNodes.count == 1)
        #expect(zipNodes[0].children.count == 2)

        let leafNodes = graph.nodes.filter {
            if case .chooseBits = $0.kind { return true }
            return false
        }
        #expect(leafNodes.count == 2)
        #expect(leafNodes.allSatisfy { $0.positionRange != nil })
    }

    @Test("Single bind produces bind node with inner and bound children")
    func singleBind() {
        let inner = ChoiceTree.choice(ChoiceValue(42 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let bound = ChoiceTree.choice(ChoiceValue(7 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let tree = ChoiceTree.bind(fingerprint: 0, inner: inner, bound: bound)

        let graph = ChoiceGraph.build(from: tree)

        let bindNodes = graph.nodes.filter {
            if case .bind = $0.kind { return true }
            return false
        }
        #expect(bindNodes.count == 1)
        #expect(bindNodes[0].children.count == 2)

        // Inner child is a chooseBits leaf.
        if case let .bind(metadata) = bindNodes[0].kind {
            let innerChild = graph.nodes[bindNodes[0].children[metadata.innerChildIndex]]
            if case .chooseBits = innerChild.kind {
                #expect(innerChild.positionRange != nil)
            } else {
                Issue.record("Inner child should be chooseBits")
            }
        }
    }

    @Test("Nested binds produce dependency chain in topological order")
    func nestedBinds() {
        let valA = ChoiceTree.choice(ChoiceValue(10 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valB = ChoiceTree.choice(ChoiceValue(20 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valC = ChoiceTree.choice(ChoiceValue(30 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let innerBind = ChoiceTree.bind(fingerprint: 0, inner: valB, bound: valC)
        let outerBind = ChoiceTree.bind(fingerprint: 0, inner: valA, bound: innerBind)

        let graph = ChoiceGraph.build(from: outerBind)

        let bindNodes = graph.nodes.filter {
            if case .bind = $0.kind { return true }
            return false
        }
        #expect(bindNodes.count == 2)

        // Dependency edges should connect outer bind-inner to inner bind.
        #expect(graph.dependencyEdges.isEmpty == false)
    }

    @Test("Pick site with two branches produces pick node with active and inactive children")
    func pickSite() {
        let branchA = ChoiceTree.branch(
            fingerprint: 1000, weight: 1, id: 0, branchCount: 2,
            choice: .choice(ChoiceValue(10 as UInt64, tag: .uint64), .init(validRange: 0 ... 100))
        )
        let branchB = ChoiceTree.branch(
            fingerprint: 1000, weight: 1, id: 1, branchCount: 2,
            choice: .choice(ChoiceValue(20 as UInt64, tag: .uint64), .init(validRange: 0 ... 100))
        )
        let tree = ChoiceTree.group([branchA, branchB.selecting()])

        let graph = ChoiceGraph.build(from: tree)

        let pickNodes = graph.nodes.filter {
            if case .pick = $0.kind { return true }
            return false
        }
        #expect(pickNodes.count == 1)

        if case let .pick(metadata) = pickNodes[0].kind {
            #expect(metadata.fingerprint == 1000)
            #expect(metadata.selectedID == 1)
            #expect(metadata.branchCount == 2)
        }

        // Should have children — at least the active branch.
        #expect(pickNodes[0].children.isEmpty == false)

        // Active branch has position range; inactive branch does not.
        let activeChildren = pickNodes[0].children.filter { graph.nodes[$0].positionRange != nil }
        let inactiveChildren = pickNodes[0].children.filter { graph.nodes[$0].positionRange == nil }
        #expect(activeChildren.count == 1)
        #expect(inactiveChildren.count == 1)
    }

    @Test("Sequence node with element children")
    func sequenceNode() {
        let elementA = ChoiceTree.choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10))
        let elementB = ChoiceTree.choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10))
        let tree = ChoiceTree.sequence(
            length: 2,
            elements: [elementA, elementB],
            .init(validRange: 0 ... 5, isRangeExplicit: true)
        )

        let graph = ChoiceGraph.build(from: tree)

        let sequenceNodes = graph.nodes.filter {
            if case .sequence = $0.kind { return true }
            return false
        }
        #expect(sequenceNodes.count == 1)

        if case let .sequence(metadata) = sequenceNodes[0].kind {
            #expect(metadata.elementCount == 2)
            #expect(metadata.lengthConstraint == 0 ... 5)
        }

        #expect(sequenceNodes[0].children.count == 2)
    }

    @Test("getSize-bind is transparent — bound content appears directly")
    func getSizeBindTransparent() {
        let inner = ChoiceTree.getSize(100)
        let bound = ChoiceTree.choice(ChoiceValue(42 as UInt64, tag: .uint64), .init(validRange: 0 ... 100))
        let tree = ChoiceTree.bind(fingerprint: 0, inner: inner, bound: bound)

        let graph = ChoiceGraph.build(from: tree)

        // No bind node should exist — getSize-bind is transparent.
        let bindNodes = graph.nodes.filter {
            if case .bind = $0.kind { return true }
            return false
        }
        #expect(bindNodes.isEmpty)

        // The bound content should appear directly as a chooseBits leaf.
        let leafNodes = graph.nodes.filter {
            if case .chooseBits = $0.kind { return true }
            return false
        }
        #expect(leafNodes.count == 1)
    }

    @Test("Opaque zip preserves isOpaque flag")
    func opaqueZip() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10)),
        ], isOpaque: true)

        let graph = ChoiceGraph.build(from: tree)

        let zipNodes = graph.nodes.filter {
            if case .zip = $0.kind { return true }
            return false
        }
        #expect(zipNodes.count == 1)
        if case let .zip(metadata) = zipNodes[0].kind {
            #expect(metadata.isOpaque)
        }
    }

    // MARK: - Edge Layer Tests

    @Test("Dependency edges exist for nested binds")
    func dependencyEdgesForNestedBinds() {
        let valA = ChoiceTree.choice(ChoiceValue(10 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valB = ChoiceTree.choice(ChoiceValue(20 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valC = ChoiceTree.choice(ChoiceValue(30 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let innerBind = ChoiceTree.bind(fingerprint: 0, inner: valB, bound: valC)
        let outerBind = ChoiceTree.bind(fingerprint: 0, inner: valA, bound: innerBind)

        let graph = ChoiceGraph.build(from: outerBind)

        #expect(graph.dependencyEdges.isEmpty == false)

        // Verify that each dependency edge references valid nodes in the graph.
        for edge in graph.dependencyEdges {
            #expect(edge.source < graph.nodes.count, "Dependency edge source out of bounds")
            #expect(edge.target < graph.nodes.count, "Dependency edge target out of bounds")
            #expect(edge.source != edge.target, "Dependency edge should not be self-referential")
        }
    }

    @Test("Containment edges form tree structure")
    func containmentEdgesFormTree() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10)),
            .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10)),
        ])

        let graph = ChoiceGraph.build(from: tree)

        // Two containment edges: zip → leaf1, zip → leaf2.
        #expect(graph.containmentEdges.count == 2)
        #expect(graph.containmentEdges.allSatisfy { $0.source == 0 })
    }

    @Test("Self-similarity groups index by fingerprint")
    func selfSimilarityGroups() {
        // Two pick sites with the same fingerprint should be grouped together.
        let pickA = ChoiceTree.group([
            .branch(fingerprint: 42, weight: 1, id: 0, branchCount: 2,
                    choice: .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10))),
            .branch(fingerprint: 42, weight: 1, id: 1, branchCount: 2,
                    choice: .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10)),
                    isSelected: true),
        ])
        let pickB = ChoiceTree.group([
            .branch(fingerprint: 42, weight: 1, id: 0, branchCount: 2,
                    choice: .choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 10))),
            .branch(fingerprint: 42, weight: 1, id: 1, branchCount: 2,
                    choice: .choice(ChoiceValue(4 as UInt64, tag: .uint64), .init(validRange: 0 ... 10)),
                    isSelected: true),
        ])
        let tree = ChoiceTree.group([pickA, pickB])

        let graph = ChoiceGraph.build(from: tree)

        // Both picks share fingerprint 42, so they should be in the same group.
        let group = graph.selfSimilarityGroups[42]
        #expect(group?.count == 2)
    }

    @Test("Self-similarity groups exclude inactive picks")
    func selfSimilarityExcludesInactivePicks() {
        // A single pick site — only one active pick, no group of size >= 2 possible.
        let tree = ChoiceTree.group([
            .branch(fingerprint: 1000, weight: 1, id: 0, branchCount: 2,
                    choice: .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10))),
            .branch(fingerprint: 1000, weight: 1, id: 1, branchCount: 2,
                    choice: .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10)),
                    isSelected: true),
        ])

        let graph = ChoiceGraph.build(from: tree)

        // One active pick with fingerprint 1000 — group has size 1, no self-similar pairs possible.
        let group = graph.selfSimilarityGroups[1000]
        #expect(group?.count == 1)
    }

    // MARK: - Query Tests

    @Test("Deletion antichain excludes individual leaf nodes")
    func deletionAntichainExcludesLeaves() {
        // A zip of three leaves — the zip is in the antichain, not the individual leaves.
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10)),
            .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10)),
            .choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 10)),
        ])

        let graph = ChoiceGraph.build(from: tree)
        let antichain = graph.deletionAntichain

        // The zip node has children, so it's a candidate. Individual leaves have no children.
        // The antichain should contain at most the zip node.
        for nodeID in antichain {
            #expect(graph.nodes[nodeID].children.isEmpty == false,
                    "Antichain member \(nodeID) should have children (structural boundary)")
        }
    }

    @Test("Leaf nodes returns all active chooseBits nodes")
    func leafNodesQuery() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10)),
            .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10)),
        ])

        let graph = ChoiceGraph.build(from: tree)
        let leaves = graph.leafNodes

        #expect(leaves.count == 2)
        for leafID in leaves {
            if case .chooseBits = graph.nodes[leafID].kind {
                #expect(graph.nodes[leafID].positionRange != nil)
            } else {
                Issue.record("Leaf node \(leafID) should be chooseBits")
            }
        }
    }

    @Test("Structural fingerprint changes when structure changes")
    func structuralFingerprintChanges() {
        let treeA = ChoiceTree.group([
            .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10)),
            .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10)),
        ])
        let treeB = ChoiceTree.group([
            .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10)),
            .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10)),
            .choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 10)),
        ])

        let graphA = ChoiceGraph.build(from: treeA)
        let graphB = ChoiceGraph.build(from: treeB)

        #expect(graphA.structuralFingerprint != graphB.structuralFingerprint)
    }

    @Test("Structural fingerprint is stable for same tree")
    func structuralFingerprintStable() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 10)),
            .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 10)),
        ])

        let graphA = ChoiceGraph.build(from: tree)
        let graphB = ChoiceGraph.build(from: tree)

        #expect(graphA.structuralFingerprint == graphB.structuralFingerprint)
    }
}
