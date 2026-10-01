import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Fixed leaf proposals")
struct LeafProposalCursorTests {
    @Test("Rejected ladders preserve both directions and UInt64 endpoint behavior", arguments: rejectedLadderCases)
    func rejectedLadderMatchesRecordedOrder(current: UInt64, target: UInt64, expected: [UInt64]) {
        #expect(LeafCandidates.rejectedBinarySearch(current: current, target: target) == expected)
    }

    @Test("Domain and binary proposals reject a scope whose leaf position is not a value")
    func malformedLeafPositionRejected() {
        let tree = ChoiceTree.uint64(2, in: 0 ... 3)
        let graph = ChoiceGraph.build(from: tree)
        let scope = EncoderInput(
            transformation: GraphTransformation(
                operation: .minimize(.valueLeaves(.init(
                    leaves: [.init(nodeID: 0, mayReshapeOnAcceptance: false)],
                    batchZeroEligible: false
                ))),
                priority: DispatchPriority(
                    structuralBenefit: 0,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: 1
                )
            ),
            baseSequence: [.just],
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        )
        let candidates = [
            LeafCandidates.candidates(in: 0 ... 3, current: 2, target: 0, includesCurrent: false),
            LeafCandidates.rejectedBinarySearch(current: 2, target: 0),
        ]
        for values in candidates {
            #expect(LeafProposalCursor(scope: scope, leafNodeID: 0, candidates: values) == nil)
        }
    }

    @Test("Fixed ladders reproduce the adaptive encoder's full choices and mutations under rejection")
    func rejectedLadderPreservesMetadata() throws {
        let trees: [ChoiceTree] = [
            .uint64(100, in: 0 ... 1000),
            .uint64(UInt64.max),
            .int64(-30),
            .int64(30),
            .int64(Int64.min),
        ]
        for tree in trees {
            let graph = ChoiceGraph.build(from: tree)
            let sequence = ChoiceSequence(tree)
            let leafNodeID = try #require(graph.leafNodes.first)
            guard case let .chooseBits(metadata) = graph.nodes[leafNodeID].kind else {
                Issue.record("Expected an integer leaf")
                return
            }
            let scope = EncoderInput(
                transformation: GraphTransformation(
                    operation: .minimize(.valueLeaves(.init(
                        leaves: [.init(nodeID: leafNodeID, mayReshapeOnAcceptance: false)],
                        batchZeroEligible: false
                    ))),
                    priority: DispatchPriority(
                        structuralBenefit: 0,
                        valueBenefit: 0,
                        reductionMagnitude: 0,
                        estimatedCost: 1
                    )
                ),
                baseSequence: sequence,
                tree: tree,
                graph: graph,
                warmStartRecords: [:]
            )
            var cursor = try #require(LeafProposalCursor(
                scope: scope,
                leafNodeID: leafNodeID,
                candidates: LeafCandidates.rejectedBinarySearch(
                    current: metadata.value.bitPattern64,
                    target: metadata.value.reductionTarget(in: metadata.validRange)
                )
            ))
            var adaptive = GraphBinarySearchEncoder()
            adaptive.start(scope: scope)
            var candidate = sequence
            var expected = sequence
            while let proposal = cursor.next(into: &candidate) {
                let next = adaptive.nextProbe(into: &expected, lastAccepted: false)
                let mutation = try #require(next)
                #expect(Array(candidate) == Array(expected))
                #expect(Array(proposal.prefix) == Array(expected))
                #expect(ProbeTraceRecorder.Mutation(proposal.mutation) == ProbeTraceRecorder.Mutation(mutation))
            }
            #expect(adaptive.nextProbe(into: &expected, lastAccepted: false) == nil)
        }
    }
}

private let rejectedLadderCases: [(UInt64, UInt64, [UInt64])] = [
    (100, 0, [50, 75, 88, 94, 97, 99]),
    (0, 100, [50, 25, 12, 6, 3, 1, 0]),
    (UInt64.max, 0, (0 ... 63).reversed().map { UInt64.max - (UInt64(1) << $0) }),
    (0, UInt64.max, (0 ... 63).reversed().map { UInt64(1) << $0 } + [0]),
    (UInt64.max, UInt64.max - 1, [UInt64.max - 1]),
    (UInt64.max - 1, UInt64.max, [UInt64.max, UInt64.max - 1]),
    (1, 0, [0]),
    (0, 1, [1, 0]),
    (42, 42, []),
]
