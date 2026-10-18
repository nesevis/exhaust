import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Recurring zip field groups")
struct RecurringZipQueryTests {
    @Test("Matching zip shapes at different pick sites or branches remain separate", arguments: [false, true])
    func unrelatedSitesStaySeparate(changeFingerprint: Bool) {
        let record = ChoiceTree.uint64Zip([12, 13], in: 0 ... 100)
        let graph = GraphFixture(.group([
            .pickSite(fingerprint: 10, selected: 0, branches: [record, record]),
            .pickSite(fingerprint: changeFingerprint ? 11 : 10, selected: changeFingerprint ? 0 : 1, branches: [record, record]),
        ])).graph
        #expect(PositionRelativeQuery.build(graph: graph).isEmpty)
    }

    @Test("Recurring fields retain all leaf-domain distinctions", arguments: RoleDomainDifference.allCases)
    func incompatibleDomainsStaySeparate(difference: RoleDomainDifference) {
        let graph = GraphFixture(.group([
            .pickSite(fingerprint: 10, selected: 0, branches: [.group([difference.leaf(changed: false)])]),
            .pickSite(fingerprint: 10, selected: 0, branches: [.group([difference.leaf(changed: true)])]),
        ])).graph
        #expect(PositionRelativeQuery.build(graph: graph).isEmpty)
    }

    @Test("A nearest pick without zipped fields does not borrow an outer zip's context")
    func scalarPicksDoNotBorrowZipRoles() {
        let scalar = ChoiceTree.pickSite(fingerprint: 11, selected: 0, branches: [.uint64(12, in: 0 ... 100)])
        let record = recurringRecord(score: scalar, marker: .just)
        let graph = GraphFixture(.group([record, record])).graph
        #expect(PositionRelativeQuery.build(graph: graph).isEmpty)
    }

    @Test("Unanchored zips and target-only recurring fields add no roles")
    func irrelevantZipsAddNoGroups() {
        let record = ChoiceTree.uint64Zip([12, 13], in: 0 ... 100)
        #expect(PositionRelativeQuery.build(graph: GraphFixture(.group([record, record])).graph).isEmpty)
        let target = recurringRecord(score: .uint64(0, in: 0 ... 100), marker: .uint64(0, in: 0 ... 100))
        #expect(PositionRelativeQuery.build(graph: GraphFixture(.group([target, target])).graph).isEmpty)
    }

    @Test("Sequence instances retain ownership even when their elements use the same pick site")
    func sequencesKeepOwnership() {
        let record = recurringRecord(score: .uint64(12, in: 0 ... 100), marker: .uint64(13, in: 0 ... 100))
        let collection = ChoiceTree.sequence(elements: [record, record], metadata: .init(validRange: 2 ... 2))
        let graph = GraphFixture(.group([collection, collection])).graph
        let leaves = graph.leafNodes
        #expect(PositionRelativeQuery.build(graph: graph).map(\.nodeIDs) == [
            [leaves[0], leaves[2]],
            [leaves[1], leaves[3]],
            [leaves[4], leaves[6]],
            [leaves[5], leaves[7]],
        ])
        let singleton = ChoiceTree.sequence(elements: [record], metadata: .init(validRange: 1 ... 1))
        #expect(PositionRelativeQuery.build(graph: GraphFixture(.group([singleton, singleton])).graph).isEmpty)
    }

    @Test("Inactive branches and depth or lane controls do not become recurring fields")
    func inactiveAndControlLeavesExcluded() {
        let controls = ChoiceTree.group([
            recurringLeaf(12, tag: .depthControl),
            recurringLeaf(12, tag: .laneControl),
        ])
        let record = ChoiceTree.pickSite(
            fingerprint: 10,
            selected: 0,
            branches: [controls, .uint64Zip([12, 13], in: 0 ... 100)]
        )
        #expect(PositionRelativeQuery.build(graph: GraphFixture(.group([record, record])).graph).isEmpty)
    }

    @Test("Bind-site fingerprints distinguish otherwise corresponding zip fields")
    func bindSitesStaySeparate() {
        let records = [UInt64(10), 11].map { fingerprint in
            recurringRecord(
                score: .bind(fingerprint: fingerprint, inner: .uint64(12, in: 0 ... 100), bound: .just),
                marker: .just
            )
        }
        #expect(PositionRelativeQuery.build(graph: GraphFixture(.group(records)).graph).isEmpty)
    }
}

private func recurringLeaf(_ value: UInt64, tag: TypeTag) -> ChoiceTree {
    .choice(
        ChoiceValue(tag.makeConvertible(bitPattern64: tag.simplestBitPattern + value), tag: tag),
        .init(validRange: tag.simplestBitPattern ... tag.simplestBitPattern + 100, isRangeExplicit: true)
    )
}

private func recurringRecord(score: ChoiceTree, marker: ChoiceTree, child: ChoiceTree = .just) -> ChoiceTree {
    .pickSite(fingerprint: 42, selected: 1, branches: [.just, .group([score, marker, child])])
}
