import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Proposal cursor value semantics")
struct ProposalCursorTests {
    @Test("Leaf proposals retain their order and earlier values across cursor copies")
    func leafCopies() throws {
        let tree = ChoiceTree.uint64(100, in: 0 ... 1000)
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let leafID = try #require(graph.leafNodes.first)
        let cursor = try #require(LeafProposalCursor(
            graph: graph,
            baseSequence: sequence,
            leafNodeID: leafID,
            candidates: [50, 75, 88, 94, 97, 99]
        ))
        let expected = [UInt64(50), 75, 88, 94, 97, 99].map { value in
            ChoiceSequence(ChoiceTree.uint64(value, in: 0 ... 1000))
        }
        try assertIndependentCopies(cursor, expected: expected)
    }

    @Test("Bound exchanges preserve order while skipping overflowing transfers", arguments: [false, true])
    func exchangeCopies(overflows: Bool) throws {
        let sink: UInt64 = overflows ? UInt64.max - 3 : 25
        let tree = ChoiceTree.bind(fingerprint: 1, inner: .uint64(30, in: 0 ... 100), bound: .uint64(sink))
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let exchange = try #require(ExchangeQuery.build(graph: graph).compactMap { operation -> BoundExchangeScope? in
            guard case let .boundExchange(scope) = operation else {
                return nil
            }
            return scope
        }.first)
        let cursor = try #require(BoundExchangeProposalCursor(graph: graph, baseSequence: sequence, exchange: exchange))
        let sourceIndex = try #require(graph.nodes[exchange.sourceLeafNodeID].positionRange?.lowerBound)
        let sinkIndex = try #require(graph.nodes[exchange.sinkLeafNodeID].positionRange?.lowerBound)
        let sources: [UInt64] = overflows ? [27, 29] : [15, 23, 27, 29]
        let expected = sources.map { source in
            var candidate = sequence
            candidate[sourceIndex] = candidate[sourceIndex].withBitPattern(source)
            candidate[sinkIndex] = candidate[sinkIndex].withBitPattern(sink + (30 - source))
            return candidate
        }
        try assertIndependentCopies(cursor, expected: expected)
    }

    @Test("Bind pivots emit the plain pivot then donors from smallest to largest across copies")
    func pivotCopies() throws {
        let smallest = ChoiceTree.pickSite(fingerprint: 9, selected: 0, branches: [.uint64(3)])
        let middle = ChoiceTree.pickSite(fingerprint: 9, selected: 0, branches: [.group([.uint64(7), smallest])])
        let bound = ChoiceTree.pickSite(fingerprint: 9, selected: 0, branches: [.group([.uint64(9), middle])])
        let inner = ChoiceTree.pickSite(fingerprint: 42, selected: 1, branches: [.uint64(1), .uint64(2)])
        let tree = ChoiceTree.bind(fingerprint: 1, inner: inner, bound: bound)
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let bindID = try #require(graph.liveNodeIDs.first { nodeID in
            if case .bind = graph.nodes[nodeID].kind {
                return true
            }
            return false
        })
        guard case let .bind(metadata) = graph.nodes[bindID].kind else {
            Issue.record("Expected the enclosing bind")
            return
        }
        let pickID = graph.nodes[bindID].children[metadata.innerChildIndex]
        let boundID = graph.nodes[bindID].children[metadata.boundChildIndex]
        let boundRange = try #require(graph.nodes[boundID].positionRange)
        let scope = BindPivotScope(bindNodeID: bindID, pickNodeID: pickID, targetBranchID: 0, boundSubtreeSize: boundRange.count, estimatedProbes: 1)
        let input = EncoderInput(baseSequence: sequence, tree: tree, graph: graph, warmStartRecords: [:], tuning: ReductionTuning())
        guard case let .impure(.propose(factory, _), _) = BindPivotEncoder.reduce(scope, input: input) else {
            Issue.record("Expected a proposal factory")
            return
        }
        let cursor = try #require(factory())
        let plain = try #require(PivotCandidates.branchPivotCandidate(pickNodeID: pickID, targetBranchID: 0, sequence: sequence, graph: graph))
        let transplants = [smallest, middle].map { donor in
            var candidate = plain
            candidate.replaceSubrange(boundRange, with: ChoiceSequence(donor))
            return candidate
        }
        try assertIndependentCopies(cursor, expected: [plain] + transplants)
    }
}

/// Exhausts one copy while retaining every proposal, then advances its sibling to expose shared mutable state or reused candidate storage. Copies both before and after starting a cursor, including through the interpreter's existential storage.
private func assertIndependentCopies(_ source: any ProposalCursor, expected: [ChoiceSequence]) throws {
    for consumedCount in [0, 1, 2] {
        var cursor = AttemptCursor { source }
        var retained: [LiftProposal] = []
        for index in 0 ..< consumedCount {
            let next = cursor.next()
            let proposal = try #require(next)
            #expect(proposal.prefix.materialized() == expected[index])
            retained.append(proposal)
        }
        var sibling = cursor
        for index in consumedCount ..< expected.count {
            #expect(cursor.nextIndex == index)
            let next = cursor.next()
            let proposal = try #require(next)
            #expect(proposal.prefix.materialized() == expected[index])
            retained.append(proposal)
        }
        #expect(cursor.next() == nil)
        #expect(cursor.next() == nil)
        #expect(cursor.nextIndex == nil)
        for index in consumedCount ..< expected.count {
            #expect(sibling.nextIndex == index)
            let next = sibling.next()
            let proposal = try #require(next)
            #expect(proposal.prefix.materialized() == expected[index])
            #expect(ProbeTraceRecorder.Mutation(proposal.mutation) == ProbeTraceRecorder.Mutation(retained[index].mutation))
        }
        #expect(sibling.next() == nil)
        #expect(sibling.nextIndex == nil)
        #expect(retained.map { $0.prefix.materialized() } == expected)
    }
}
