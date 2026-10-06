import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Generated replacement and migration scopes")
struct GeneratedScopeCursorTests {
    @Test("Replacement streams match eager payloads and stable priority ties", arguments: [
        [[3, 1, 2, 1], [0, 0, 1], [4, 2, 3]],
        [[0, 0, 0]],
        [[5, 4, 3, 2, 1]],
        [[1, 2, 3, 4, 5]],
    ])
    func replacementMatchesEager(families: [[Int]]) {
        let tree = familyTree(families)
        let graph = ChoiceGraph.build(from: tree)
        var source = AnyCandidateSource.replacement(ReplacementQuery.cursor(graph: graph))
        let actual = drain(&source)
        let expected = EagerScopeReference.replacementCandidates(graph: graph)

        #expect(actual.map(signature) == expected.map(signature))
        #expect(actual.map(\.priority) == expected.map(\.priority))
        #expect(source.peekPriority == nil)
        #expect(source.next() == nil)
    }

    @Test("Discovery, priority, and pivot-only cursors preserve nested and dependent replacement behavior")
    func nestedReplacementOrdersMatchEager() {
        let inner = pick(fingerprint: 42, content: .uint64Zip([1, 2]))
        let ancestor = pick(fingerprint: 42, content: .group([.uint64(3), inner]))
        let dependent = ChoiceTree.bind(
            fingerprint: 91,
            inner: pick(fingerprint: 42, content: .uint64Zip([4, 5, 6, 7])),
            bound: pick(fingerprint: 42, content: .uint64(8))
        )
        let graph = ChoiceGraph.build(from: .group([ancestor, dependent]))
        var priority = ReplacementQuery.cursor(graph: graph)
        var discovery = ReplacementQuery.discoveryCursor(graph: graph)
        var pivots = ReplacementQuery.pivotCursor(graph: graph)
        let eagerScopes = EagerScopeReference.replacementScopes(graph: graph)

        #expect(drain(&priority).map(signature) == EagerScopeReference.replacementCandidates(graph: graph).map(signature))
        #expect(drain(&discovery).map(signature) == eagerScopes.map(replacementSignature))
        #expect(drain(&pivots).map(signature) == eagerScopes.compactMap { scope in
            guard case .branchPivot = scope else {
                return nil
            }
            return replacementSignature(scope)
        })
        #expect(eagerScopes.contains { scope in
            guard case .descendantPromotion = scope else {
                return false
            }
            return true
        })
    }

    @Test("Incremental replacement preparation suppresses unchanged families but retains pivots")
    func incrementalReplacementMatchesEager() {
        let previous = ChoiceGraph.build(from: familyTree([[3, 1, 2], [2, 2]]))
        let graph = ChoiceGraph.build(from: familyTree([[3, 1, 2], [2, 1]]))
        var changed = ReplacementQuery.cursor(graph: graph, previousGraph: previous)
        var unchanged = ReplacementQuery.cursor(graph: graph, previousGraph: graph)

        #expect(drain(&changed).map(signature) == EagerScopeReference.replacementCandidates(graph: graph, previousGraph: previous).map(signature))
        let unchangedScopes = drain(&unchanged)
        #expect(unchangedScopes.map(signature) == EagerScopeReference.replacementCandidates(graph: graph, previousGraph: graph).map(signature))
        #expect(unchangedScopes.isEmpty == false)
        #expect(unchangedScopes.allSatisfy { transformation in
            guard case .replace(.branchPivot) = transformation.operation else {
                return false
            }
            return true
        })
    }

    @Test("Pivot cursors honor constant-arm exclusions and the alternative leaf-count gate")
    func pivotEligibilityMatchesEager() throws {
        let tree = ChoiceTree.group([2, 1, 1].map { size in
            ChoiceTree.pickSite(
                fingerprint: 42,
                selected: 1,
                branches: [.just, .uint64Zip(Array(repeating: 1, count: size)), .uint64Zip([50, 51, 52]), .uint64(50)]
            )
        })
        var graph = ChoiceGraph.build(from: tree)
        let pickNodeID = try #require(graph.liveNodeIDs.first { nodeID in
            if case .pick = graph.nodes[nodeID].kind {
                return true
            }
            return false
        })
        guard case let .pick(metadata) = graph.nodes[pickNodeID].kind else {
            Issue.record("Expected a pick node")
            return
        }
        graph.excludedPivots.insert(ExcludedPivot(
            fingerprint: metadata.fingerprint,
            constantBranchID: 0,
            armDomainSignature: ExcludedPivot.armDomainSignature(of: metadata)
        ))
        var cursor = ReplacementQuery.pivotCursor(graph: graph)
        let actual = drain(&cursor)
        let expected = EagerScopeReference.replacementScopes(graph: graph).compactMap { scope -> Signature? in
            guard case .branchPivot = scope else {
                return nil
            }
            return replacementSignature(scope)
        }
        #expect(actual.map(signature) == expected)
        #expect(actual.allSatisfy { transformation in
            guard case let .replace(.branchPivot(_, branchID)) = transformation.operation else {
                return false
            }
            return branchID != 0
        })
        #expect(actual.allSatisfy { transformation in
            guard case let .replace(.branchPivot(_, branchID)) = transformation.operation else {
                return false
            }
            return branchID != 2
        })
    }

    @Test("Migration streams preserve priority ties, capacity gates, containment, dependencies, and wrapper extents")
    func migrationMatchesEager() {
        let wrapped = sequence([
            .bind(fingerprint: 19, inner: .just, bound: .uint64(1)),
            .bind(fingerprint: 19, inner: .just, bound: .uint64(2)),
        ])
        let nested = sequence([.uint64Sequence([3, 4]), .uint64Sequence([5])])
        let dependent = ChoiceTree.bind(
            fingerprint: 20,
            inner: .uint64Sequence([6, 7]),
            bound: .uint64Sequence([8])
        )
        let fullReceiver = sequence([.uint64(9)], maximumLength: 1)
        let trees: [ChoiceTree] = [
            .group([.uint64Sequence([1, 2, 3]), .uint64Sequence([4]), .uint64Sequence([5]), .uint64Sequence([])]),
            .group([wrapped, nested, dependent, fullReceiver, .uint64Sequence([])]),
            .group([fullReceiver, fullReceiver]),
            .just,
        ]
        for tree in trees {
            let graph = ChoiceGraph.build(from: tree)
            var source = AnyCandidateSource.migration(MigrationCandidateSource(graph: graph))
            let actual = drain(&source)
            let expected = EagerScopeReference.migrationCandidates(graph: graph)
            #expect(actual.map(signature) == expected.map(signature))
            #expect(actual.map(\.priority) == expected.map(\.priority))
            #expect(source.peekPriority == nil)
        }
    }

    @Test("Replacement cursor copies resume independently with identical priorities")
    func copiedCursorsResumeIndependently() throws {
        let graph = ChoiceGraph.build(from: familyTree([[5, 1, 3, 1], [2, 0, 2]]))
        var source = AnyCandidateSource.replacement(ReplacementQuery.cursor(graph: graph))
        for _ in 0 ..< 3 {
            _ = try #require(pullScope(from: &source))
        }
        var copied = source
        let copiedPriority = copied.peekPriority
        _ = try #require(pullScope(from: &source))
        #expect(copied.peekPriority == copiedPriority)
        let remainingCopy = drain(&copied)
        let remainingSource = drain(&source)
        #expect(remainingCopy.dropFirst().map(signature) == remainingSource.map(signature))
    }

    @Test("Structural cursors do not retain the mutable graph node buffer")
    func graphValuesRemainWritableWithoutCopyingNodes() throws {
        let tree = ChoiceTree.group([familyTree([[2, 1]]), .uint64Sequence([1, 2]), .uint64Sequence([3])])
        var graph = ChoiceGraph.build(from: tree)
        var replacement = ReplacementQuery.cursor(graph: graph)
        var migration = MigrationCandidateSource(graph: graph)
        let leafNodeID = try #require(graph.leafNodes.first)
        let originalAddress = graph.nodes.withUnsafeBufferPointer { $0.baseAddress }
        guard case let .chooseBits(metadata) = graph.nodes[leafNodeID].kind else {
            Issue.record("Expected a numeric leaf")
            return
        }
        graph.nodes[leafNodeID] = graph.nodes[leafNodeID].with(kind: .chooseBits(ChooseBitsMetadata(
            typeTag: metadata.typeTag,
            validRange: metadata.validRange,
            isRangeExplicit: metadata.isRangeExplicit,
            value: ChoiceValue(UInt64(9), tag: .uint64),
            typeTagPayload: metadata.typeTagPayload
        )))
        let updatedAddress = graph.nodes.withUnsafeBufferPointer { $0.baseAddress }
        #expect(updatedAddress == originalAddress)
        #expect(replacement.next() != nil)
        #expect(migration.next() != nil)
    }

    @Test("A short replacement prefix does not require materializing a 5000-node family's pairs")
    func largeReplacementPrefix() throws {
        let count = 5000
        let tree = ChoiceTree.group((0 ..< count).map { _ in
            ChoiceTree.pickSite(fingerprint: 77, selected: 0, branches: [.just])
        })
        let graph = ChoiceGraph.build(from: tree)
        let members = try #require(graph.selfSimilarityGroups[77])
        #expect(members.count == count)
        var source = AnyCandidateSource.replacement(ReplacementQuery.cursor(graph: graph))
        for donorIndex in 1 ... 32 {
            let expectedPriority = source.peekPriority
            let transformation = try #require(pullScope(from: &source))
            #expect(signature(transformation) == .selfSimilar(members[0], members[donorIndex], 0))
            #expect(transformation.priority == expectedPriority)
        }
        #expect(source.peekPriority != nil)
    }

    @Test("A short migration prefix does not require materializing every pair of 3000 sequences")
    func largeMigrationPrefix() throws {
        let count = 3000
        let graph = ChoiceGraph.build(from: .group((0 ..< count).map { _ in .uint64Sequence([1]) }))
        var source = AnyCandidateSource.migration(MigrationCandidateSource(graph: graph))
        var sourceNodeIDs: [Int] = []
        var receiverNodeIDs: [Int] = []
        for _ in 0 ..< 32 {
            let expectedPriority = source.peekPriority
            let transformation = try #require(pullScope(from: &source))
            guard case let .migrate(scope) = transformation.operation else {
                Issue.record("Expected a migration")
                return
            }
            sourceNodeIDs.append(scope.sourceSequenceNodeID)
            receiverNodeIDs.append(scope.receiverSequenceNodeID)
            #expect(transformation.priority == expectedPriority)
        }
        #expect(Set(sourceNodeIDs).count == 1)
        #expect(Set(receiverNodeIDs).count == 32)
        #expect(receiverNodeIDs == receiverNodeIDs.sorted())
        #expect(source.peekPriority != nil)
    }
}

// MARK: - Fixtures

private enum Signature: Equatable {
    case selfSimilar(Int, Int, Int)
    case pivot(Int, UInt64)
    case promotion(Int, Int, Int)
    case migration(Int, Int, [Int], [ClosedRange<Int>], ClosedRange<Int>, Int?)
    case unexpected
}

private func signature(_ transformation: GraphTransformation) -> Signature {
    switch transformation.operation {
        case let .replace(scope):
            replacementSignature(scope)
        case let .migrate(scope):
            .migration(
                scope.sourceSequenceNodeID,
                scope.receiverSequenceNodeID,
                scope.elementNodeIDs,
                scope.elementPositionRanges,
                scope.receiverPositionRange,
                scope.sourceParentSequenceNodeID
            )
        default:
            .unexpected
    }
}

private func replacementSignature(_ scope: ReplacementScope) -> Signature {
    switch scope {
        case let .selfSimilar(target, donor, sizeDelta):
            .selfSimilar(target, donor, sizeDelta)
        case let .branchPivot(nodeID, branchID):
            .pivot(nodeID, branchID)
        case let .descendantPromotion(ancestor, descendant, sizeDelta):
            .promotion(ancestor, descendant, sizeDelta)
    }
}

/// Checks every advertised priority against the emitted scope while consuming through the shared contract.
private func drain(_ source: inout some CandidateSource) -> [GraphTransformation] {
    var transformations: [GraphTransformation] = []
    while let expectedPriority = source.peekPriority {
        guard let transformation = source.next() else {
            Issue.record("A source advertising priority must emit a scope")
            break
        }
        #expect(transformation.priority == expectedPriority)
        transformations.append(transformation)
    }
    #expect(source.next() == nil)
    return transformations
}

private func pick(fingerprint: UInt64, content: ChoiceTree) -> ChoiceTree {
    .pickSite(fingerprint: fingerprint, selected: 1, branches: [.just, content, .uint64(50)])
}

private func familyTree(_ families: [[Int]]) -> ChoiceTree {
    .group(families.enumerated().flatMap { familyIndex, sizes in
        sizes.map { size in
            pick(fingerprint: UInt64(42 + familyIndex), content: .uint64Zip(Array(repeating: 1, count: size)))
        }
    })
}

private func sequence(_ elements: [ChoiceTree], maximumLength: UInt64? = nil) -> ChoiceTree {
    .sequence(
        elements: elements,
        metadata: .init(validRange: maximumLength.map { 0 ... $0 }, isRangeExplicit: maximumLength != nil)
    )
}

private func pullScope(from source: inout some CandidateSource) -> GraphTransformation? {
    source.next()
}
