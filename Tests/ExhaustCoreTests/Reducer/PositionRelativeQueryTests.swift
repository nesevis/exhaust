import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Position-relative field groups")
struct PositionRelativeQueryTests {
    @Test("Corresponding fields exclude equal-valued decoys", arguments: [TypeTag.uint64, .int64], [2, 3, 5])
    func fieldsExcludeDecoys(tag: TypeTag, count: Int) throws {
        let record = ChoiceTree.group([roleLeaf(12, tag: tag), roleLeaf(12, tag: tag)])
        let fixture = GraphFixture(.sequence(
            elements: Array(repeating: record, count: count),
            metadata: .init(validRange: UInt64(count) ... UInt64(count))
        ))
        let leaves = fixture.graph.leafNodes
        let expected = [
            (0 ..< count).map { leaves[$0 * 2] },
            (0 ..< count).map { leaves[$0 * 2 + 1] },
        ]
        let groups = PositionRelativeQuery.build(graph: fixture.graph)
        #expect(groups.map(\.nodeIDs) == expected)
        #expect(groups.map(\.typeTag) == Array(repeating: tag, count: 2))
        let tandem = try #require(ExchangeQuery.build(graph: fixture.graph).tandemScope)
        #expect(tandem.groups.prefix(2).map { $0.leaves.map(\.nodeID) } == expected)
        #expect(tandem.groups.contains { $0.leaves.map(\.nodeID) == leaves })

        var encoder = GraphLockstepEncoder()
        encoder.start(scope: roleEncoderInput(group: tandem.groups[0], fixture: fixture))
        var candidate = fixture.sequence
        let mutation = try #require(encoder.nextProbe(into: &candidate, lastAccepted: false))
        #expect(candidate.compactMap { $0.value?.choice.bitPattern64 } == (0 ..< count).flatMap { _ in
            [tag.simplestBitPattern, tag.simplestBitPattern + 12]
        })
        guard case let .leafValues(changes) = mutation else {
            Issue.record("Expected a leaf mutation")
            return
        }
        #expect(changes.map(\.leafNodeID).sorted() == expected[0])
    }

    @Test("Negative signed fields move toward zero without changing equal-valued decoys")
    func negativeFieldsExcludeDecoys() throws {
        let record = ChoiceTree.group([.int64(-12), .int64(-12)])
        let fixture = GraphFixture(.sequence(elements: [record, record], metadata: .init(validRange: 2 ... 2)))
        let tandem = try #require(ExchangeQuery.build(graph: fixture.graph).tandemScope)
        var encoder = GraphLockstepEncoder()
        encoder.start(scope: roleEncoderInput(group: tandem.groups[0], fixture: fixture))
        var candidate = fixture.sequence
        _ = try #require(encoder.nextProbe(into: &candidate, lastAccepted: false))
        let unchanged = ChoiceValue(-12 as Int64, tag: .int64).bitPattern64
        #expect(candidate.compactMap { $0.value?.choice.bitPattern64 } == [
            TypeTag.int64.simplestBitPattern,
            unchanged,
            TypeTag.int64.simplestBitPattern,
            unchanged,
        ])
    }

    @Test("Roles do not require whole records or corresponding choices to be equal")
    func unequalRecordsShareRoles() {
        let graph = GraphFixture(.sequence(
            elements: [.uint64Zip([12, 12], in: 0 ... 100), .uint64Zip([13, 14], in: 0 ... 100)],
            metadata: .init(validRange: 2 ... 2)
        )).graph
        #expect(PositionRelativeQuery.build(graph: graph).map(\.nodeIDs) == [
            [graph.leafNodes[0], graph.leafNodes[2]],
            [graph.leafNodes[1], graph.leafNodes[3]],
        ])
    }

    @Test("Changing another field does not destroy its structural correspondence")
    func valueRefreshPreservesRoles() {
        let record = ChoiceTree.uint64Zip([12, 12], in: 0 ... 100)
        var graph = GraphFixture(.sequence(elements: [record, record], metadata: .init(validRange: 2 ... 2))).graph
        let expected = PositionRelativeQuery.build(graph: graph).map(\.nodeIDs)
        graph.applyLeafValueWrite(LeafChange(
            leafNodeID: graph.leafNodes[3],
            newValue: ChoiceValue(13 as UInt64, tag: .uint64),
            mayReshape: false
        ))
        #expect(expected.count == 2)
        #expect(PositionRelativeQuery.build(graph: graph).map(\.nodeIDs) == expected)
    }

    @Test("Incompatible leaf domains and types do not share a role", arguments: RoleDomainDifference.allCases)
    func incompatibleDomainsStaySeparate(difference: RoleDomainDifference) {
        let graph = GraphFixture(.sequence(
            elements: [.group([difference.leaf(changed: false)]), .group([difference.leaf(changed: true)])],
            metadata: .init(validRange: 2 ... 2)
        )).graph
        #expect(PositionRelativeQuery.build(graph: graph).isEmpty)
    }

    @Test("Pick selections and generator fingerprints remain significant", arguments: [false, true])
    func pickContextsStaySeparate(changeFingerprint: Bool) {
        let branches: [ChoiceTree] = [.uint64(12, in: 0 ... 100), .uint64(12, in: 0 ... 100)]
        let graph = GraphFixture(.sequence(
            elements: [
                .pickSite(fingerprint: 10, selected: 0, branches: branches),
                .pickSite(fingerprint: changeFingerprint ? 11 : 10, selected: changeFingerprint ? 0 : 1, branches: branches),
            ],
            metadata: .init(validRange: 2 ... 2)
        )).graph
        #expect(PositionRelativeQuery.build(graph: graph).isEmpty)
    }

    @Test("Matching bind sites preserve inner and bound roles")
    func bindSidesStaySeparate() throws {
        let record = ChoiceTree.bind(
            fingerprint: 10,
            inner: .uint64(12, in: 0 ... 100),
            bound: .uint64(12, in: 0 ... 100)
        )
        let graph = GraphFixture(.sequence(elements: [record, record], metadata: .init(validRange: 2 ... 2))).graph
        #expect(PositionRelativeQuery.build(graph: graph).map(\.nodeIDs) == [
            [graph.leafNodes[0], graph.leafNodes[2]],
            [graph.leafNodes[1], graph.leafNodes[3]],
        ])
        let tandem = try #require(ExchangeQuery.build(graph: graph).tandemScope)
        #expect(tandem.groups[0].leaves.allSatisfy { $0.mayReshapeOnAcceptance })
        #expect(tandem.groups[1].leaves.allSatisfy { $0.mayReshapeOnAcceptance == false })
    }

    @Test("Different bind sites do not become corresponding merely by position")
    func differentBindSitesStaySeparate() {
        let records = [UInt64(10), 11].map { fingerprint in
            ChoiceTree.bind(
                fingerprint: fingerprint,
                inner: .uint64(12, in: 0 ... 100),
                bound: .uint64(12, in: 0 ... 100)
            )
        }
        let graph = GraphFixture(.sequence(elements: records, metadata: .init(validRange: 2 ... 2))).graph
        #expect(PositionRelativeQuery.build(graph: graph).isEmpty)
    }

    @Test("The nearest sequence owns a role and unrelated collections remain separate")
    func nestedSequencesStaySeparate() {
        let items = ChoiceTree.uint64Sequence([12, 13], in: 0 ... 100)
        let record = ChoiceTree.group([.uint64(12, in: 0 ... 100), items])
        let graph = GraphFixture(.sequence(elements: [record, record], metadata: .init(validRange: 2 ... 2))).graph
        #expect(PositionRelativeQuery.build(graph: graph).map(\.nodeIDs) == [
            [graph.leafNodes[0], graph.leafNodes[3]],
            [graph.leafNodes[1], graph.leafNodes[2]],
            [graph.leafNodes[4], graph.leafNodes[5]],
        ])
    }

    @Test("Singleton inner sequences do not borrow correspondence from an outer sequence")
    func singletonSequencesStaySeparate() {
        let items = ChoiceTree.uint64Sequence([12], in: 0 ... 100)
        let graph = GraphFixture(.sequence(elements: [items, items], metadata: .init(validRange: 2 ... 2))).graph
        #expect(PositionRelativeQuery.build(graph: graph).isEmpty)
    }

    @Test("Inactive branches and depth or lane controls never contribute field groups")
    func inactiveAndControlLeavesExcluded() {
        let controls = ChoiceTree.group([
            roleLeaf(12, tag: .depthControl),
            roleLeaf(12, tag: .laneControl),
        ])
        let inactive = ChoiceTree.sequence(
            elements: [.uint64Zip([12, 12], in: 0 ... 100), .uint64Zip([12, 12], in: 0 ... 100)],
            metadata: .init(validRange: 2 ... 2)
        )
        let graph = GraphFixture(.group([
            .sequence(elements: [controls, controls], metadata: .init(validRange: 2 ... 2)),
            .pickSite(fingerprint: 10, selected: 0, branches: [.just, inactive]),
        ])).graph
        #expect(PositionRelativeQuery.build(graph: graph).isEmpty)
    }

    @Test("A role already covered by broad tandem search adds no duplicate group")
    func existingGroupsAreNotDuplicated() throws {
        let graph = GraphFixture(.uint64Sequence([12, 13], in: 0 ... 100)).graph
        #expect(PositionRelativeQuery.build(graph: graph).map(\.nodeIDs) == [graph.leafNodes])
        let tandem = try #require(ExchangeQuery.build(graph: graph).tandemScope)
        #expect(tandem.groups.count == 1)
        #expect(tandem.groups[0].leaves.map(\.nodeID) == graph.leafNodes)
    }

    @Test("A duplicate role retains its place in broad subgroup ordering")
    func duplicateRoleKeepsBroadOrdering() throws {
        let graph = GraphFixture(.sequence(
            elements: [.uint64Zip([12, 13], in: 0 ... 100), .uint64Zip([12, 14], in: 0 ... 100)],
            metadata: .init(validRange: 2 ... 2)
        )).graph
        let leaves = graph.leafNodes
        let tandem = try #require(ExchangeQuery.build(graph: graph).tandemScope)
        #expect(tandem.groups.map { $0.leaves.map(\.nodeID) } == [
            [leaves[1], leaves[3]],
            leaves,
            [leaves[0], leaves[2]],
        ])
    }

    @Test("Role ordering follows sequence positions rather than node identifiers")
    func rolesFollowPositions() {
        let record = ChoiceTree.uint64Zip([12, 13], in: 0 ... 100)
        var graph = GraphFixture(.sequence(elements: [record, record], metadata: .init(validRange: 2 ... 2))).graph
        let leaves = graph.leafNodes
        for (position, nodeID) in [leaves[1], leaves[0], leaves[3], leaves[2]].enumerated() {
            let node = graph.nodes[nodeID]
            graph.nodes[nodeID] = ChoiceGraphNode(
                id: node.id,
                kind: node.kind,
                positionRange: position ... position,
                children: node.children,
                parent: node.parent,
                choicePath: node.choicePath,
                scopeAnnotation: node.scopeAnnotation
            )
        }
        let groups = PositionRelativeQuery.build(graph: graph)
        #expect(groups.map(\.nodeIDs) == [
            [leaves[1], leaves[3]],
            [leaves[0], leaves[2]],
        ])
        #expect(groups.allSatisfy { $0.nodeIDs == $0.nodeIDs.sorted() })
    }

    @Test("Existing equal-value subgroups remain available")
    func equalValueFallbackRemains() throws {
        let graph = GraphFixture(.sequence(
            elements: [.uint64Zip([12, 12], in: 0 ... 100), .uint64Zip([13, 12], in: 0 ... 100)],
            metadata: .init(validRange: 2 ... 2)
        )).graph
        let tandem = try #require(ExchangeQuery.build(graph: graph).tandemScope)
        #expect(tandem.groups.contains { $0.leaves.map(\.nodeID) == graph.leafNodes })
        #expect(tandem.groups.contains { $0.leaves.map(\.nodeID) == [graph.leafNodes[0], graph.leafNodes[1], graph.leafNodes[3]] })
    }

    @Test("Target-only roles and graphs without repeated sequences add no groups")
    func irrelevantShapesAddNoGroups() {
        let target = ChoiceTree.uint64Zip([0, 0], in: 0 ... 100)
        let graph = GraphFixture(.sequence(elements: [target, target], metadata: .init(validRange: 2 ... 2))).graph
        #expect(PositionRelativeQuery.build(graph: graph).isEmpty)
        let tree = ChoiceTree.bind(
            fingerprint: 10,
            inner: .uint64(12, in: 0 ... 100),
            bound: .uint64Zip([12, 12], in: 0 ... 100)
        )
        #expect(PositionRelativeQuery.build(graph: GraphFixture(tree).graph).isEmpty)
        let singleton = ChoiceTree.uint64Sequence([12], in: 0 ... 100)
        #expect(PositionRelativeQuery.build(graph: GraphFixture(singleton).graph).isEmpty)
    }
}

// MARK: - Test helpers

private func roleLeaf(_ value: UInt64, tag: TypeTag) -> ChoiceTree {
    .choice(
        ChoiceValue(tag.makeConvertible(bitPattern64: tag.simplestBitPattern + value), tag: tag),
        .init(validRange: tag.simplestBitPattern ... tag.simplestBitPattern + 100, isRangeExplicit: true)
    )
}

/// Uses the same sequence and graph as the query so emitted mutations can be checked at their actual positions.
private func roleEncoderInput(group: TandemGroup, fixture: GraphFixture) -> EncoderInput {
    EncoderInput(
        transformation: GraphTransformation(
            operation: .exchange(.tandem(TandemScope(groups: [group]))),
            priority: DispatchPriority(structuralBenefit: 0, valueBenefit: 0, reductionMagnitude: 0, estimatedCost: 1)
        ),
        baseSequence: fixture.sequence,
        tree: fixture.tree,
        graph: fixture.graph,
        warmStartRecords: [:]
    )
}

/// Changes only the leaf-domain component of an otherwise identical positional role.
enum RoleDomainDifference: CaseIterable {
    case range
    case explicitness
    case payload
    case leafType

    /// Keeps the relative path fixed while changing one leaf's domain metadata.
    func leaf(changed: Bool) -> ChoiceTree {
        let tag: TypeTag = switch self {
            case .payload:
                .character
            case .leafType:
                changed ? .uint32 : .uint64
            case .range, .explicitness:
                .uint64
        }
        let payload: TypeTagPayload? = switch self {
            case .payload:
                .character(problematicIndices: [changed ? 2 : 1], simplifications: .empty)
            case .range, .explicitness, .leafType:
                nil
        }
        return .choice(
            ChoiceValue(tag.makeConvertible(bitPattern64: 12), tag: tag),
            .init(
                validRange: 0 ... (self == .range && changed ? 101 : 100),
                isRangeExplicit: self == .explicitness && changed == false,
                typeTagPayload: payload
            )
        )
    }
}
