import ExhaustTestSupport
import Testing
@testable import ExhaustCore

/// Each property drains a streaming scope query and compares it with the eager builder it replaced, over generated graphs. The counters check that the generator reached nonempty streams, so a property cannot pass by never exercising the query.
@Suite("Scope query differential properties")
struct ScopeQueryDifferentialPropertyTests {
    @Test("Compatibility edges and redistribution pairs match the eager builders, including statistics and scheduling metadata")
    func exchangeStreamsMatchEager() throws {
        var nonemptyEdgeStreams = 0
        var nonemptyPairStreams = 0
        try exhaustCheck(ChoiceTreeGenerators.scopeTrees, maxIterations: iterations) { tree in
            let graph = ChoiceGraph.build(from: tree)
            let expectedEdges = EagerExchangeReference.typeCompatibilityEdges(graph: graph)
            var edges = TypeCompatibilityCursor(graph: graph)
            let edgeCount = edges.edgeCount
            let actualEdges = drain(&edges)

            let expectedPairs = EagerExchangeReference.redistributionPairs(graph: graph)
            var pairs = GeneratedRedistributionPairCursor(graph: graph)
            let summary = pairs.summary()
            let actualPairs = drain(&pairs)

            let expectedDistance = maximumSourceDistance(of: expectedPairs, graph: graph)
            let redistribution = CandidateSourceBuilder.buildExchangeCandidates(graph: graph).first { transformation in
                guard case .exchange(.redistribution) = transformation.operation else {
                    return false
                }
                return true
            }
            let schedulesRedistribution = switch redistribution {
                case let .some(transformation):
                    expectedPairs.isEmpty == false
                        && transformation.priority.reductionMagnitude == Int(min(expectedDistance, UInt64(Int.max)))
                        && transformation.priority.estimatedCost == min(24, expectedPairs.count)
                case .none:
                    expectedPairs.isEmpty
            }

            nonemptyEdgeStreams += expectedEdges.isEmpty ? 0 : 1
            nonemptyPairStreams += expectedPairs.isEmpty ? 0 : 1
            return actualEdges == expectedEdges
                && edgeCount == expectedEdges.count
                && ChoiceGraphStats.from(graph).typeCompatibilityEdgeCount == expectedEdges.count
                && schedulesRedistribution
                && actualPairs.map(RedistributionPairSignature.init) == expectedPairs.map(RedistributionPairSignature.init)
                && summary.pairCount == expectedPairs.count
                && summary.maximumSourceDistance == expectedDistance
        }
        #expect(nonemptyEdgeStreams >= minimumNonemptyStreams)
        #expect(nonemptyPairStreams >= minimumNonemptyStreams)
    }

    @Test("Priority, discovery, and pivot-only replacement streams match the eager builder through both buffered and merged enumeration")
    func replacementStreamsMatchEager() throws {
        var nonemptyStreams = 0
        var selfSimilarStreams = 0
        var promotionStreams = 0
        try exhaustCheck(ChoiceTreeGenerators.scopeTrees, maxIterations: iterations) { tree in
            let graph = ChoiceGraph.build(from: tree)
            let expectedCandidates = EagerScopeReference.replacementCandidates(graph: graph)
            let expectedScopes = EagerScopeReference.replacementScopes(graph: graph)
            var priority = ReplacementQuery.cursor(graph: graph)
            var discovery = ReplacementQuery.discoveryCursor(graph: graph)
            var pivots = ReplacementQuery.pivotCursor(graph: graph)
            var mergedPriority = ReplacementCandidateSource(graph: graph, order: .priority, eagerRowLimit: 0)
            var mergedDiscovery = ReplacementCandidateSource(graph: graph, order: .discovery, eagerRowLimit: 0)
            var mergedPivots = ReplacementCandidateSource(pivotGraph: graph, eagerRowLimit: 0)
            let actualCandidates = drainCheckingPriorities(&priority)
            let mergedCandidates = drainCheckingPriorities(&mergedPriority)

            nonemptyStreams += expectedCandidates.isEmpty ? 0 : 1
            selfSimilarStreams += expectedScopes.contains(where: \.isSelfSimilar) ? 1 : 0
            promotionStreams += expectedScopes.contains(where: \.isDescendantPromotion) ? 1 : 0
            return actualCandidates?.map(TransformationSignature.init) == expectedCandidates.map(TransformationSignature.init)
                && actualCandidates?.map(\.priority) == expectedCandidates.map(\.priority)
                && drainCheckingPriorities(&discovery)?.map(TransformationSignature.init) == expectedScopes.map(TransformationSignature.init)
                && drainCheckingPriorities(&pivots)?.map(TransformationSignature.init) == expectedScopes.filter(\.isBranchPivot).map(TransformationSignature.init)
                && mergedCandidates?.map(TransformationSignature.init) == expectedCandidates.map(TransformationSignature.init)
                && mergedCandidates?.map(\.priority) == expectedCandidates.map(\.priority)
                && drainCheckingPriorities(&mergedDiscovery)?.map(TransformationSignature.init) == expectedScopes.map(TransformationSignature.init)
                && drainCheckingPriorities(&mergedPivots)?.map(TransformationSignature.init) == expectedScopes.filter(\.isBranchPivot).map(TransformationSignature.init)
        }
        #expect(nonemptyStreams >= minimumNonemptyStreams)
        #expect(selfSimilarStreams >= minimumNonemptyStreams)
        #expect(promotionStreams >= minimumNonemptyStreams)
    }

    @Test("Incremental replacement preparation suppresses the same families as the eager builder")
    func incrementalReplacementMatchesEager() throws {
        let generator = Gen.zip(ChoiceTreeGenerators.scopeTrees, ChoiceTreeGenerators.scopeTrees, Gen.choose(in: 0 ... 1))
        var nonemptyStreams = 0
        try exhaustCheck(generator, maxIterations: iterations) { sample in
            let (tree, otherTree, reusesTree) = sample
            let graph = ChoiceGraph.build(from: tree)
            // Rebuilding from the same tree makes every family unchanged; an unrelated tree leaves most of them changed.
            let previousGraph = ChoiceGraph.build(from: reusesTree == 1 ? tree : otherTree)
            let expected = EagerScopeReference.replacementCandidates(graph: graph, previousGraph: previousGraph)
            var cursor = ReplacementQuery.cursor(graph: graph, previousGraph: previousGraph)
            var merged = ReplacementCandidateSource(graph: graph, previousGraph: previousGraph, eagerRowLimit: 0)
            let actual = drainCheckingPriorities(&cursor)
            let mergedActual = drainCheckingPriorities(&merged)

            nonemptyStreams += expected.isEmpty ? 0 : 1
            return actual?.map(TransformationSignature.init) == expected.map(TransformationSignature.init)
                && actual?.map(\.priority) == expected.map(\.priority)
                && mergedActual?.map(TransformationSignature.init) == expected.map(TransformationSignature.init)
                && mergedActual?.map(\.priority) == expected.map(\.priority)
        }
        #expect(nonemptyStreams >= minimumNonemptyStreams)
    }

    @Test("Migration streams match the eager builder, including priority ties and dependency gates")
    func migrationStreamsMatchEager() throws {
        var nonemptyStreams = 0
        try exhaustCheck(ChoiceTreeGenerators.scopeTrees, maxIterations: iterations) { tree in
            let graph = ChoiceGraph.build(from: tree)
            let expected = EagerScopeReference.migrationCandidates(graph: graph)
            var source = MigrationCandidateSource(graph: graph)
            let actual = drainCheckingPriorities(&source)

            nonemptyStreams += expected.isEmpty ? 0 : 1
            return actual?.map(TransformationSignature.init) == expected.map(TransformationSignature.init)
                && actual?.map(\.priority) == expected.map(\.priority)
        }
        #expect(nonemptyStreams >= minimumNonemptyStreams)
    }

    @Test("Relation pairs over stalled leaves match the eager all-pairs scan")
    func relationPairsMatchEager() throws {
        var nonemptyStreams = 0
        try exhaustCheck(ChoiceTreeGenerators.scopeTrees, maxIterations: iterations) { tree in
            let graph = ChoiceGraph.stalled(from: tree)
            let expected = EagerExchangeReference.relationPairs(graph: graph)
            var cursor = RelationPairCursor(graph: graph)
            let actual = drain(&cursor)

            nonemptyStreams += expected.isEmpty ? 0 : 1
            return actual.map(RelationPairSignature.init) == expected.map(RelationPairSignature.init)
        }
        #expect(nonemptyStreams >= minimumNonemptyStreams)
    }

    @Test("The relax cursor emits the eager length-sorted prefix and counts every eager candidate")
    func relaxCandidatesMatchEager() throws {
        let generator = Gen.zip(ChoiceTreeGenerators.scopeTrees, Gen.choose(in: 0 ... 8))
        var nonemptyStreams = 0
        try exhaustCheck(generator, maxIterations: iterations) { tree, limit in
            let graph = ChoiceGraph.build(from: tree)
            let sequence = ChoiceSequence(tree)
            let expected = EagerScopeReference.relaxCandidates(sequence: sequence, graph: graph)
            var cursor = RelaxCandidateCursor(sequence: sequence, graph: graph, limit: limit)
            let candidateCount = cursor.candidateCount
            let retainedCandidateCount = cursor.retainedCandidateCount
            let actual = drain(&cursor)

            nonemptyStreams += expected.isEmpty ? 0 : 1
            return actual == Array(expected.prefix(limit))
                && candidateCount == expected.count
                && retainedCandidateCount == min(limit, expected.count)
        }
        #expect(nonemptyStreams >= minimumNonemptyStreams)
    }

    @Test("Improving pivot probes match the eager fills absent from the pass-entry cache, constructed only on demand")
    func improvingPivotCandidatesMatchEager() throws {
        let generator = Gen.zip(ChoiceTreeGenerators.scopeTrees, Gen.choose(in: UInt64(0) ... UInt64.max), Gen.choose(in: 0 ... 8))
        var nonemptyStreams = 0
        try exhaustCheck(generator, maxIterations: iterations) { sample in
            let (tree, cacheMask, prefixLength) = sample
            let graph = ChoiceGraph.build(from: tree)
            let sequence = ChoiceSequence(tree)
            let candidates = EagerScopeReference.improvingPivotCandidates(sequence: sequence, graph: graph)
            // Each mask bit decides whether one eager candidate was already rejected before the pass started.
            let rejectCache = Set(candidates.enumerated().compactMap { index, candidate in
                (cacheMask >> UInt64(index % 64)) & 1 == 1 ? ZobristHash.hash(of: candidate) : nil
            })
            let expected = candidates.filter { rejectCache.contains(ZobristHash.hash(of: $0)) == false }
            var cursor = ImprovingPivotCandidateCursor(sequence: sequence, graph: graph, rejectCache: rejectCache)
            let constructsLazily = cursor.constructedCandidateCount == 0
            var partial = cursor
            let prefix = (0 ..< prefixLength).compactMap { _ in partial.next() }
            let actual = drain(&cursor)

            nonemptyStreams += candidates.isEmpty ? 0 : 1
            return constructsLazily
                && prefix.map(\.sequence) == Array(expected.prefix(prefixLength))
                && actual.map(\.sequence) == expected
                && actual.allSatisfy { $0.probeHash == ZobristHash.hash(of: $0.sequence) }
        }
        #expect(nonemptyStreams >= minimumNonemptyStreams)
    }
}

// MARK: - Supporting Types

private let iterations: UInt64 = 2000

/// One in 20 generated graphs must reach each counted case, so a generator change that stops reaching a query fails rather than passing on empty streams. Recheck the measured rates against this floor after changing the generator.
private let minimumNonemptyStreams = Int(iterations / 20)

/// Compares every emitted pair field without adding test-only conformances to production scopes.
private struct RedistributionPairSignature: Equatable {
    let source: LeafEntrySignature
    let sink: LeafEntrySignature
    let sourceTag: TypeTag
    let sinkTag: TypeTag

    init(_ pair: RedistributionPair) {
        source = LeafEntrySignature(pair.source)
        sink = LeafEntrySignature(pair.sink)
        sourceTag = pair.sourceTag
        sinkTag = pair.sinkTag
    }
}

private struct RelationPairSignature: Equatable {
    let first: LeafEntrySignature
    let second: LeafEntrySignature
    let numerator: UInt64
    let denominator: UInt64
    let scale: UInt64

    init(_ pair: RelationPair) {
        first = LeafEntrySignature(pair.first)
        second = LeafEntrySignature(pair.second)
        numerator = pair.numerator
        denominator = pair.denominator
        scale = pair.scale
    }
}

private struct LeafEntrySignature: Equatable {
    let nodeID: Int
    let mayReshapeOnAcceptance: Bool
    let bindDepth: Int?

    init(_ entry: LeafEntry) {
        nodeID = entry.nodeID
        mayReshapeOnAcceptance = entry.mayReshapeOnAcceptance
        bindDepth = entry.bindDepth
    }
}

private enum TransformationSignature: Equatable {
    case selfSimilar(target: Int, donor: Int, sizeDelta: Int)
    case pivot(pick: Int, branch: UInt64)
    case promotion(ancestor: Int, descendant: Int, sizeDelta: Int)
    case migration(source: Int, receiver: Int, elements: [Int], extents: [ClosedRange<Int>], receiverRange: ClosedRange<Int>, sourceParent: Int?)
    case unexpected

    init(_ transformation: GraphTransformation) {
        switch transformation.operation {
            case let .replace(scope):
                self.init(scope)
            case let .migrate(scope):
                self = .migration(
                    source: scope.sourceSequenceNodeID,
                    receiver: scope.receiverSequenceNodeID,
                    elements: scope.elementNodeIDs,
                    extents: scope.elementPositionRanges,
                    receiverRange: scope.receiverPositionRange,
                    sourceParent: scope.sourceParentSequenceNodeID
                )
            default:
                self = .unexpected
        }
    }

    init(_ scope: ReplacementScope) {
        switch scope {
            case let .selfSimilar(target, donor, sizeDelta):
                self = .selfSimilar(target: target, donor: donor, sizeDelta: sizeDelta)
            case let .branchPivot(pick, branch):
                self = .pivot(pick: pick, branch: branch)
            case let .descendantPromotion(ancestor, descendant, sizeDelta):
                self = .promotion(ancestor: ancestor, descendant: descendant, sizeDelta: sizeDelta)
        }
    }
}

private extension ReplacementScope {
    var isBranchPivot: Bool {
        guard case .branchPivot = self else {
            return false
        }
        return true
    }

    var isSelfSimilar: Bool {
        guard case .selfSimilar = self else {
            return false
        }
        return true
    }

    var isDescendantPromotion: Bool {
        guard case .descendantPromotion = self else {
            return false
        }
        return true
    }
}

// MARK: - Helpers

private func drain<Cursor: ScopeCursor>(_ cursor: inout Cursor) -> [Cursor.Scope] {
    var scopes: [Cursor.Scope] = []
    while let scope = cursor.next() {
        scopes.append(scope)
    }
    return scopes
}

/// Returns nil when an advertised priority disagrees with the emitted scope, or when exhaustion is not reported by both peek and advancement.
private func drainCheckingPriorities(_ source: inout some CandidateSource) -> [GraphTransformation]? {
    var transformations: [GraphTransformation] = []
    while let advertised = source.peekPriority {
        guard let transformation = source.next(), transformation.priority == advertised else {
            return nil
        }
        transformations.append(transformation)
    }
    guard source.next() == nil else {
        return nil
    }
    return transformations
}

private func maximumSourceDistance(of pairs: [RedistributionPair], graph: ChoiceGraph) -> UInt64 {
    pairs.reduce(UInt64(0)) { maximum, pair in
        guard case let .chooseBits(metadata) = graph.nodes[pair.source.nodeID].kind else {
            return maximum
        }
        return max(maximum, QueryHelpers.reductionDistance(metadata))
    }
}
