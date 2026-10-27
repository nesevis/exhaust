import Testing
@testable import ExhaustCore

@Suite("Graph update policy")
struct GraphUpdatePolicyTests {
    @Test("Graph maintenance changes neither admission nor acceptance feedback", arguments: [GraphUpdatePolicy.applyMutation, .rebuildAfterPass], [false, true])
    func admissionIsIndependent(graphUpdate: GraphUpdatePolicy, mayReshape: Bool) throws {
        let generator = Gen.choose(in: UInt64(0) ... 100)
        let tree = try #require(try Interpreters.reflect(generator, with: 5))
        let base = ChoiceSequence(tree)
        let graph = ChoiceGraph.build(from: tree)
        let leafNodeID = try #require(graph.leafNodes.first)
        let position = try #require(graph.nodes[leafNodeID].positionRange?.lowerBound)

        for value: UInt64 in [4, 6] {
            let candidate = try ChoiceSequence(#require(try Interpreters.reflect(generator, with: value)))
            let choice = try #require(candidate[position].value?.choice)
            var context = Reducer.Context(
                incumbent: Counterexample(sequence: base, tree: tree, output: UInt64(5)),
                incumbentHash: ZobristHash.hash(of: base),
                graph: graph,
                rejectCache: ProbeCache(),
                decoder: ReductionDecoder(generator: generator.erase(), property: { _ in false }, probeWrapper: nil, hasBind: false),
                encoder: ValueSearchEncoder.self
            )
            context.candidateBuffer = candidate

            let evaluation = Reducer.evaluateAndCommit(
                .eager(mutation: .leafValues([LeafChange(leafNodeID: leafNodeID, newValue: choice, mayReshape: mayReshape)]), admission: .standard),
                configuration: SearchConfiguration(graphUpdate: graphUpdate),
                context: &context
            )

            let accepted = value < 5
            let appliesInPlace = accepted && graphUpdate == .applyMutation && mayReshape == false
            #expect(evaluation.isAccepted == accepted)
            #expect(evaluation.feedback.isAccepted == accepted)
            #expect(context.incumbent.sequence == (accepted ? candidate : base))
            #expect(context.baseHash == ZobristHash.hash(of: context.incumbent.sequence))
            #expect(context.report.anyAccepted == accepted)
            #expect(context.report.counts.accepted == (accepted ? 1 : 0))
            #expect(context.report.anyRequiresRebuild == (accepted && appliesInPlace == false))
            if accepted {
                guard case let .accepted(recovered) = evaluation.feedback else {
                    Issue.record("An admitted candidate must deliver its recovered sequence")
                    continue
                }
                #expect(recovered == candidate)
                #expect(context.report.acceptedLeafNodeIDs == [leafNodeID])
            } else {
                guard case .rejected(.failedNotAdmitted) = evaluation.feedback else {
                    Issue.record("The larger counterexample must be rejected by admission")
                    continue
                }
                #expect(context.report.acceptedLeafNodeIDs.isEmpty)
            }
            guard case let .chooseBits(metadata) = context.graph.nodes[leafNodeID].kind else {
                Issue.record("The graph must retain its integer leaf")
                continue
            }
            #expect(metadata.value.bitPattern64 == (appliesInPlace ? value : 5))
            if accepted, mayReshape, graphUpdate == .applyMutation {
                guard case .graphInvalidated? = evaluation.stop else {
                    Issue.record("A reshape must stop the pass when the mutation cannot be applied")
                    continue
                }
            } else {
                #expect(evaluation.stop == nil)
            }
        }
    }
}
