import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Choice graph reconciling")
struct ChoiceGraphReconcilingTests {
    // MARK: - Nodes Built Before the Change

    @Test("A bind enclosing the edited pick keeps its node ID while the nodes after the edit shift")
    func enclosingBindKeepsNodeID() throws {
        let parent = ChoiceGraph.build(from: Trees.pivotBind(selected: 0, firstBranch: .uint64(1)))
        let lifted = ChoiceGraph.build(from: Trees.pivotBind(selected: 0, firstBranch: .uint64Zip([1, 2, 3])))
        let bindID = try #require(parent.bindID(fingerprint: Trees.outerBind))
        let pickID = try #require(parent.pickID(fingerprint: Trees.pick))

        let reconciled = parent.reconciling(bindID, in: lifted, changedAt: pickID)

        #expect(reconciled == bindID)
        #expect(parent.boundLeafIDs(ofBind: Trees.outerBind) != lifted.boundLeafIDs(ofBind: Trees.outerBind))
    }

    @Test("A node before the change is not reconciled into a controller-topology graph")
    func earlierNodeRefusesControllerTopology() throws {
        let tree = Trees.pivotBind(selected: 0, firstBranch: .uint64(1))
        let parent = ChoiceGraph.build(from: tree)
        let lifted = ChoiceGraphBuilder.buildControllerTopology(from: tree)
        let bindID = try #require(parent.bindID(fingerprint: Trees.outerBind))
        let pickID = try #require(parent.pickID(fingerprint: Trees.pick))

        #expect(parent.reconciling(bindID, in: lifted, changedAt: pickID) == nil)
    }

    @Test("A node before the change is not reconciled when only one graph is missing unselected branches")
    func earlierNodeRefusesMismatchedBranchMaterialization() throws {
        let parent = ChoiceGraph.build(from: Trees.bindAfterPick(pick: Trees.strippedPick))
        let lifted = ChoiceGraph.build(from: Trees.bindAfterPick(pick: Trees.pickWithBindArm))
        let bindID = try #require(parent.bindID(fingerprint: Trees.outerBind))
        let innerID = try #require(parent.innerID(ofBind: Trees.outerBind))

        #expect(parent.lacksUnselectedBranches)
        #expect(lifted.lacksUnselectedBranches == false)
        // The stale ID lands on the unselected arm's bind, so only the missing-branches check refuses it.
        guard case .bind = lifted.nodes[bindID].kind else {
            Issue.record("Expected the stale node ID to land on a bind in the lifted graph")
            return
        }
        #expect(parent.reconciling(bindID, in: lifted, changedAt: innerID) == nil)
    }

    // MARK: - Binds After the Change

    @Test("A bind after the change is found by fingerprint and path when its node ID shifts")
    func laterBindFoundByFingerprint() throws {
        let parent = ChoiceGraph.build(from: Trees.bindAfterPick(pick: Trees.fullPick))
        let lifted = ChoiceGraph.build(from: Trees.bindAfterPick(pick: Trees.widenedPick))
        let bindID = try #require(parent.bindID(fingerprint: Trees.outerBind))
        let liftedBindID = try #require(lifted.bindID(fingerprint: Trees.outerBind))
        let pickID = try #require(parent.pickID(fingerprint: Trees.pick))

        let reconciled = parent.reconciling(bindID, in: lifted, changedAt: pickID)

        #expect(liftedBindID != bindID)
        #expect(reconciled == liftedBindID)
    }

    // MARK: - Leaves After the Change

    @Test("A nested bind's inner leaf resolves to the lifted bind's inner child")
    func innerLeafResolvesToInnerChild() throws {
        let parent = ChoiceGraph.build(from: Trees.nestedBinds(outerInner: .uint64(3), nestedBound: [6, 7]))
        let lifted = ChoiceGraph.build(from: Trees.nestedBinds(outerInner: .uint64Zip([3, 4]), nestedBound: [6, 7]))
        let changedID = try #require(parent.innerID(ofBind: Trees.outerBind))
        let sinkID = try #require(parent.innerID(ofBind: Trees.nestedBind))
        let expected = try #require(lifted.innerID(ofBind: Trees.nestedBind))

        #expect(sinkID != expected)
        #expect(parent.reconciling(sinkID, in: lifted, changedAt: changedID) == expected)
    }

    @Test("A bound leaf resolves to the same offset in a bound range of unchanged length")
    func boundLeafResolvesBySameOffset() throws {
        let parent = ChoiceGraph.build(from: Trees.nestedBinds(outerInner: .uint64(3), nestedBound: [6, 7]))
        let lifted = ChoiceGraph.build(from: Trees.nestedBinds(outerInner: .uint64Zip([3, 4]), nestedBound: [8, 9]))
        let changedID = try #require(parent.innerID(ofBind: Trees.outerBind))
        let sinkID = try #require(parent.boundLeafIDs(ofBind: Trees.nestedBind).last)
        let expected = try #require(lifted.boundLeafIDs(ofBind: Trees.nestedBind).last)

        #expect(sinkID != expected)
        #expect(parent.reconciling(sinkID, in: lifted, changedAt: changedID) == expected)
    }

    @Test("A bound leaf is not reconciled when the bound range changed length")
    func boundLeafRefusesChangedLength() throws {
        let parent = ChoiceGraph.build(from: Trees.nestedBinds(outerInner: .uint64(3), nestedBound: [6, 7]))
        let lifted = ChoiceGraph.build(from: Trees.nestedBinds(outerInner: .uint64(4), nestedBound: [6, 7, 8]))
        let changedID = try #require(parent.innerID(ofBind: Trees.outerBind))
        let sinkID = try #require(parent.boundLeafIDs(ofBind: Trees.nestedBind).last)

        #expect(parent.reconciling(sinkID, in: lifted, changedAt: changedID) == nil)
    }

    @Test("A container after the change is not reconciled")
    func laterContainerRefused() throws {
        let parent = ChoiceGraph.build(from: Trees.nestedBinds(outerInner: .uint64(3), nestedBound: [6, 7]))
        let lifted = ChoiceGraph.build(from: Trees.nestedBinds(outerInner: .uint64(4), nestedBound: [6, 7]))
        let changedID = try #require(parent.innerID(ofBind: Trees.outerBind))
        let nestedBindID = try #require(parent.bindID(fingerprint: Trees.nestedBind))
        guard case let .bind(metadata) = parent.nodes[nestedBindID].kind else {
            Issue.record("Expected a bind")
            return
        }
        let boundID = parent.nodes[nestedBindID].children[metadata.boundChildIndex]

        #expect(parent.reconciling(boundID, in: lifted, changedAt: changedID) == nil)
    }
}

// MARK: - Trees

private enum Trees {
    static let outerBind: UInt64 = 100
    static let nestedBind: UInt64 = 200
    static let pick: UInt64 = 7

    /// A pick choosing between two branches, both materialized.
    static let fullPick = ChoiceTree.pickSite(fingerprint: pick, selected: 0, branches: [.uint64(1), .uint64(2)])

    /// The same pick with its selected branch grown to three leaves, which shifts the node IDs after it.
    static let widenedPick = ChoiceTree.pickSite(fingerprint: pick, selected: 0, branches: [.uint64Zip([1, 2, 3]), .uint64(2)])

    /// A pick whose unselected arm is a bind, materialized in full.
    static let pickWithBindArm = ChoiceTree.pickSite(
        fingerprint: pick,
        selected: 0,
        branches: [.uint64(1), .bind(fingerprint: 300, inner: .uint64(0), bound: .uint64(0))]
    )

    /// The same pick holding only its selected branch, as a tree materialized without picks does.
    static let strippedPick = ChoiceTree.group([.branch(
        fingerprint: pick,
        weight: 1,
        id: 0,
        branchCount: 2,
        choice: .uint64(1),
        isSelected: true
    )])

    /// A bind whose inner child is a pick, as bind pivot edits.
    static func pivotBind(selected: Int, firstBranch: ChoiceTree) -> ChoiceTree {
        .bind(
            fingerprint: outerBind,
            inner: .pickSite(fingerprint: pick, selected: selected, branches: [firstBranch, .uint64(2)]),
            bound: .uint64Zip([4, 5])
        )
    }

    /// A pick followed by a bind.
    static func bindAfterPick(pick: ChoiceTree) -> ChoiceTree {
        .group([pick, .bind(fingerprint: outerBind, inner: .uint64(3), bound: .uint64Zip([4, 5]))])
    }

    /// An outer bind whose bound subtree holds a nested bind, as bound exchange reaches.
    static func nestedBinds(outerInner: ChoiceTree, nestedBound: [UInt64]) -> ChoiceTree {
        .bind(
            fingerprint: outerBind,
            inner: outerInner,
            bound: .bind(fingerprint: nestedBind, inner: .uint64(5), bound: .uint64Zip(nestedBound))
        )
    }
}

// MARK: - Lookup

private extension ChoiceGraph {
    func bindID(fingerprint: UInt64) -> Int? {
        liveNodeIDs.first { nodeID in
            guard case let .bind(metadata) = nodes[nodeID].kind else {
                return false
            }
            return metadata.fingerprint == fingerprint
        }
    }

    func pickID(fingerprint: UInt64) -> Int? {
        nodes.indices.first { nodeID in
            guard case let .pick(metadata) = nodes[nodeID].kind else {
                return false
            }
            return metadata.fingerprint == fingerprint
        }
    }

    func innerID(ofBind fingerprint: UInt64) -> Int? {
        guard let bindID = bindID(fingerprint: fingerprint), case let .bind(metadata) = nodes[bindID].kind else {
            return nil
        }
        return nodes[bindID].children[metadata.innerChildIndex]
    }

    func boundLeafIDs(ofBind fingerprint: UInt64) -> [Int] {
        guard let bindID = bindID(fingerprint: fingerprint),
              case let .bind(metadata) = nodes[bindID].kind,
              let boundRange = nodes[nodes[bindID].children[metadata.boundChildIndex]].positionRange
        else {
            return []
        }
        return leafNodes.filter { leafID in
            nodes[leafID].positionRange.map { boundRange.contains($0.lowerBound) } ?? false
        }
    }
}
