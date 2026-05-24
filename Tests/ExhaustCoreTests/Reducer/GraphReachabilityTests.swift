import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("ChoiceGraph Reachability and Type Compatibility")
struct GraphReachabilityTests {
    // MARK: - isReachable via Dependency Edges

    @Test("Bind-inner leaf is dependency-reachable to bound leaf")
    func bindInnerReachesToBound() {
        let tree = ChoiceTree.bind(
            fingerprint: 0,
            inner: .uint64(10, in: 0 ... 100),
            bound: .uint64(20, in: 0 ... 100)
        )
        let fixture = GraphFixture(tree)

        guard let bindNodeID = fixture.graph.liveNodeIDs.first(where: { nodeID in
            if case .bind = fixture.graph.nodes[nodeID].kind { return true }
            return false
        }) else {
            Issue.record("No bind node found")
            return
        }
        guard case let .bind(metadata) = fixture.graph.nodes[bindNodeID].kind else {
            Issue.record("Expected bind kind")
            return
        }
        let innerChildID = fixture.graph.nodes[bindNodeID].children[metadata.innerChildIndex]
        let boundChildID = fixture.graph.nodes[bindNodeID].children[metadata.boundChildIndex]

        #expect(
            fixture.graph.isReachable(from: innerChildID, to: boundChildID) == true,
            "Dependency edge inner→bound means inner can reach bound"
        )
        #expect(
            fixture.graph.isReachable(from: boundChildID, to: innerChildID) == false,
            "Dependency edges are directed — bound cannot reach inner"
        )
    }

    @Test("Sibling zip children are not dependency-reachable")
    func zipSiblingsNotReachable() {
        let fixture = GraphFixture(.uint64Zip([10, 20], in: 0 ... 100))

        let chooseBitsNodes = fixture.graph.liveNodeIDs.filter { nodeID in
            if case .chooseBits = fixture.graph.nodes[nodeID].kind { return true }
            return false
        }
        guard chooseBitsNodes.count >= 2 else {
            Issue.record("Need at least two chooseBits nodes")
            return
        }

        #expect(fixture.graph.isReachable(from: chooseBitsNodes[0], to: chooseBitsNodes[1]) == false)
        #expect(fixture.graph.isReachable(from: chooseBitsNodes[1], to: chooseBitsNodes[0]) == false)
    }

    @Test("Out-of-bounds node IDs return false")
    func outOfBoundsReturnsFalse() {
        let fixture = GraphFixture(.uint64(10, in: 0 ... 100))
        #expect(fixture.graph.isReachable(from: 999, to: 0) == false)
        #expect(fixture.graph.isReachable(from: 0, to: 999) == false)
    }

    // MARK: - reachableNodes

    @Test("reachableNodes returns bound descendants from inner node")
    func reachableNodesFromInner() {
        let tree = ChoiceTree.bind(
            fingerprint: 0,
            inner: .uint64(10, in: 0 ... 100),
            bound: .uint64Zip([20, 30], in: 0 ... 100)
        )
        let fixture = GraphFixture(tree)

        guard let bindNodeID = fixture.graph.liveNodeIDs.first(where: { nodeID in
            if case .bind = fixture.graph.nodes[nodeID].kind { return true }
            return false
        }) else {
            Issue.record("No bind node")
            return
        }
        guard case let .bind(metadata) = fixture.graph.nodes[bindNodeID].kind else {
            Issue.record("Expected bind kind")
            return
        }
        let innerChildID = fixture.graph.nodes[bindNodeID].children[metadata.innerChildIndex]
        let boundChildID = fixture.graph.nodes[bindNodeID].children[metadata.boundChildIndex]
        let candidates = Set(fixture.graph.liveNodeIDs)
        let reachable = fixture.graph.reachableNodes(from: innerChildID, within: candidates)

        #expect(reachable.contains(boundChildID),
                "Inner node should reach the bound child via dependency edge")
    }

    @Test("reachableNodes excludes the source node itself")
    func reachableNodesExcludesSource() {
        let tree = ChoiceTree.bind(
            fingerprint: 0,
            inner: .uint64(10, in: 0 ... 100),
            bound: .uint64(20, in: 0 ... 100)
        )
        let fixture = GraphFixture(tree)

        guard let bindNodeID = fixture.graph.liveNodeIDs.first(where: { nodeID in
            if case .bind = fixture.graph.nodes[nodeID].kind { return true }
            return false
        }) else {
            Issue.record("No bind node")
            return
        }
        guard case let .bind(metadata) = fixture.graph.nodes[bindNodeID].kind else {
            Issue.record("Expected bind kind")
            return
        }
        let innerChildID = fixture.graph.nodes[bindNodeID].children[metadata.innerChildIndex]
        let candidates = Set(fixture.graph.liveNodeIDs)
        let reachable = fixture.graph.reachableNodes(from: innerChildID, within: candidates)

        #expect(reachable.contains(innerChildID) == false, "Source node should not be in its own reachable set")
    }

    @Test("reachableNodes returns empty set for leaf node with no outgoing dependencies")
    func reachableFromLeafIsEmpty() {
        let fixture = GraphFixture(.uint64(10, in: 0 ... 100))

        let leafNode = fixture.graph.liveNodeIDs.first { nodeID in
            if case .chooseBits = fixture.graph.nodes[nodeID].kind { return true }
            return false
        }
        guard let leafNode else {
            Issue.record("No leaf node")
            return
        }

        let candidates = Set(fixture.graph.liveNodeIDs)
        let reachable = fixture.graph.reachableNodes(from: leafNode, within: candidates)
        #expect(reachable.isEmpty)
    }

    // MARK: - Type Compatibility Edges

    @Test("Zip with two leaves of different types produces type compatibility edges")
    func heterogeneousZipProducesEdges() {
        let tree = ChoiceTree.group([
            .uint64(10, in: 0 ... 100),
            .int64(20),
        ])
        let fixture = GraphFixture(tree)
        #expect(fixture.graph.typeCompatibilityEdges.isEmpty == false)
    }

    @Test("Single leaf produces no type compatibility edges")
    func singleLeafNoEdges() {
        let fixture = GraphFixture(.uint64(10, in: 0 ... 100))
        #expect(fixture.graph.typeCompatibilityEdges.isEmpty)
    }
}
