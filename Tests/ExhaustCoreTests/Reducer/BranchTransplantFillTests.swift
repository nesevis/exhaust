import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Branch witness transplantation")
struct BranchTransplantFillTests {
    @Test("A smaller inactive arm retains the selected arm's narrow witness and surrounding entries")
    func copiesWitnessIntoSmallerArm() throws {
        let fixture = GraphFixture(.group([
            .uint64(777),
            .pickSite(fingerprint: 42, selected: 1, branches: [
                .uint64Zip([0], in: 0 ... 100),
                .uint64Zip([37, 5], in: 0 ... 100),
            ]),
            .uint64(888),
        ]))
        let candidate = try #require(try transplantCandidate(fixture: fixture, graph: fixture.graph))
        #expect(candidate.compactMap { $0.value?.choice.bitPattern64 } == [777, 37, 888])
        #expect(candidate.shortLexPrecedes(fixture.sequence))
        #expect(candidate.count < fixture.sequence.count)
        #expect(candidate.contains { element in
            guard case let .branch(branch) = element else {
                return false
            }
            return branch.id == 0 && branch.fingerprint == 42
        })
    }

    @Test("Unmatched target fields stay minimized and copied fields retain target-domain metadata")
    func retainsTargetDomainsAndMinimizesUnmatchedFields() throws {
        let fixture = GraphFixture(.pickSite(fingerprint: 42, selected: 1, branches: [
            .group([.uint64(0, in: 0 ... 50), .int64(9)]),
            .uint64Zip([37, 12, 5], in: 0 ... 100),
        ]))
        let candidate = try #require(try transplantCandidate(fixture: fixture, graph: fixture.graph))
        let values = candidate.compactMap(\.value)
        #expect(values.map { $0.choice.bitPattern64 } == [37, TypeTag.int64.simplestBitPattern])
        #expect(values[0].validRange == 0 ... 50)
        #expect(values[0].isRangeExplicit)
        #expect(values[1].choice.tag == .int64)
    }

    @Test("A witness outside the target domain does not produce a transplant")
    func incompatibleRangeAddsNoCandidate() throws {
        let fixture = GraphFixture(.pickSite(fingerprint: 42, selected: 1, branches: [
            .uint64Zip([0], in: 0 ... 20),
            .uint64Zip([37, 5], in: 0 ... 100),
        ]))
        #expect(try transplantCandidate(fixture: fixture, graph: fixture.graph) == nil)
    }

    @Test("Transplantation reads refreshed graph values rather than recorded selected-arm samples")
    func usesCurrentGraphValues() throws {
        let fixture = GraphFixture(.pickSite(fingerprint: 42, selected: 1, branches: [
            .uint64Zip([0], in: 0 ... 100),
            .uint64Zip([37, 5], in: 0 ... 100),
        ]))
        var graph = fixture.graph
        graph.applyLeafValueWrite(LeafChange(
            leafNodeID: graph.leafNodes[0],
            newValue: ChoiceValue(UInt64(41), tag: .uint64),
            mayReshape: false
        ))
        let candidate = try #require(try transplantCandidate(fixture: fixture, graph: graph))
        #expect(candidate.compactMap { $0.value?.choice.bitPattern64 } == [41])
    }

    @Test("Dynamic source or target shapes are not treated as stable field layouts", arguments: [false, true], DynamicPivotShape.allCases)
    private func dynamicShapesAddNoCandidate(dynamicSource: Bool, shape: DynamicPivotShape) throws {
        let fixed = ChoiceTree.uint64Zip([37], in: 0 ... 100)
        let fixture = GraphFixture(.pickSite(fingerprint: 42, selected: 1, branches: [
            dynamicSource ? fixed : shape.tree,
            dynamicSource ? shape.tree : fixed,
        ]))
        #expect(try transplantCandidate(fixture: fixture, graph: fixture.graph) == nil)
    }

    @Test("Different character payloads do not justify copying a witness")
    func incompatiblePayloadAddsNoCandidate() throws {
        let fixture = GraphFixture(.pickSite(fingerprint: 42, selected: 1, branches: [
            .group([RoleDomainDifference.payload.leaf(changed: false)]),
            .group([RoleDomainDifference.payload.leaf(changed: true), .uint64(5)]),
        ]))
        #expect(try transplantCandidate(fixture: fixture, graph: fixture.graph) == nil)
    }

    @Test("A transplant identical to the minimal fill adds no candidate")
    func targetOnlyWitnessAddsNoCandidate() throws {
        let fixture = GraphFixture(.pickSite(fingerprint: 42, selected: 1, branches: [
            .uint64Zip([12], in: 0 ... 100),
            .uint64Zip([0, 5], in: 0 ... 100),
        ]))
        #expect(try transplantCandidate(fixture: fixture, graph: fixture.graph) == nil)
    }

    @Test("Branch-element indices do not substitute for graph-child indices")
    func emptyBranchDoesNotHideTarget() throws {
        let fixture = GraphFixture(.pickSite(fingerprint: 42, selected: 2, branches: [
            .getSize(10),
            .uint64Zip([0], in: 0 ... 100),
            .uint64Zip([37, 5], in: 0 ... 100),
        ]))
        let nodeID = try pivotNodeID(in: fixture.graph)
        #expect(fixture.graph.nodes[nodeID].children.count == 2)
        let candidate = try #require(GraphStructuralEncoder.branchPivotCandidate(
            pickNodeID: nodeID,
            targetBranchID: 1,
            fill: .transplanted,
            sequence: fixture.sequence,
            graph: fixture.graph
        ))
        #expect(candidate.compactMap { $0.value?.choice.bitPattern64 } == [37])
        #expect(candidate.shortLexPrecedes(fixture.sequence))
        #expect(candidate.contains { element in
            guard case let .branch(branch) = element else {
                return false
            }
            return branch.id == 1
        })
    }

    @Test("Equal-length fills can differ in precedence despite selecting the same branch")
    func fillsHaveDifferentPrecedence() throws {
        let fixture = GraphFixture(.pickSite(fingerprint: 42, selected: 1, branches: [
            .uint64Zip([0], in: 0 ... 100),
            .uint64Zip([37], in: 0 ... 100),
        ]))
        let nodeID = try pivotNodeID(in: fixture.graph)
        let recorded = try #require(GraphStructuralEncoder.branchPivotCandidate(
            pickNodeID: nodeID,
            targetBranchID: 0,
            fill: .recorded,
            sequence: fixture.sequence,
            graph: fixture.graph
        ))
        let transplanted = try #require(try transplantCandidate(fixture: fixture, graph: fixture.graph))
        #expect(recorded.count == fixture.sequence.count)
        #expect(transplanted.count == recorded.count)
        #expect(recorded.shortLexPrecedes(fixture.sequence))
        #expect(transplanted.shortLexPrecedes(fixture.sequence) == false)
    }

    @Test("A transplant can precede the source even when the recorded fill does not")
    func transplantCanImproveAfterRecordedFillFailsPrecedence() throws {
        let target = ChoiceTree.group([
            .uint64(80, in: 0 ... 100),
            .choice(ChoiceValue(UInt32(40), tag: .uint32), .init(validRange: 0 ... 100)),
        ])
        let fixture = GraphFixture(.pickSite(fingerprint: 42, selected: 1, branches: [
            target,
            .uint64Zip([37, 5], in: 0 ... 100),
        ]))
        let recorded = try #require(try GraphStructuralEncoder.branchPivotCandidate(
            pickNodeID: pivotNodeID(in: fixture.graph),
            targetBranchID: 0,
            fill: .recorded,
            sequence: fixture.sequence,
            graph: fixture.graph
        ))
        let transplanted = try #require(try transplantCandidate(fixture: fixture, graph: fixture.graph))
        #expect(recorded.count == fixture.sequence.count)
        #expect(recorded.shortLexPrecedes(fixture.sequence) == false)
        #expect(transplanted.compactMap { $0.value?.choice.bitPattern64 } == [37, 0])
        #expect(transplanted.shortLexPrecedes(fixture.sequence))
    }
}

private func pivotNodeID(in graph: ChoiceGraph) throws -> Int {
    try #require(graph.liveNodeIDs.first { nodeID in
        if case .pick = graph.nodes[nodeID].kind {
            return true
        }
        return false
    })
}

private func transplantCandidate(fixture: GraphFixture, graph: ChoiceGraph) throws -> ChoiceSequence? {
    try GraphStructuralEncoder.branchPivotCandidate(
        pickNodeID: pivotNodeID(in: graph),
        targetBranchID: 0,
        fill: .transplanted,
        sequence: fixture.sequence,
        graph: graph
    )
}

private enum DynamicPivotShape: CaseIterable {
    case sequence
    case bind
    case pick

    var tree: ChoiceTree {
        switch self {
            case .sequence:
                return .uint64Sequence([37], in: 0 ... 100)
            case .bind:
                return .bind(fingerprint: 11, inner: .uint64(37, in: 0 ... 100), bound: .just)
            case .pick:
                return .pickSite(fingerprint: 11, selected: 0, branches: [.uint64(37, in: 0 ... 100)])
        }
    }
}
