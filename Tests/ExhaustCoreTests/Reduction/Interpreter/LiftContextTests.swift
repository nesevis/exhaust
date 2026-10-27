import Testing
@testable import ExhaustCore

@Suite("Lift context")
struct LiftContextTests {
    enum ContinuationPath: CaseIterable {
        case immediate, sequential, proposed, lifted, failedLift
    }

    @Test("Lifted acceptance recovers through the first lift and ends the pass", arguments: ContinuationPath.allCases, [GraphUpdatePolicy.applyMutation, .rebuildAfterPass])
    func inheritedRecovery(path: ContinuationPath, graphUpdate: GraphUpdatePolicy) throws {
        let fixture = try LiftFixture()
        let proposal = try fixture.proposal(value: 4)
        let nestedProposal = try fixture.proposal(value: 3, nodeID: 999)
        let candidate = try fixture.sequence(value: 2)
        let rejected = try fixture.sequence(value: 6)
        var resumedAfterAcceptance = false
        var observedChanges: [LeafChange] = []
        let terminal: Reduction = .search(
            SingleCandidateSearch(candidate: candidate, mutation: nestedProposal.mutation),
            configuration: SearchConfiguration(graphUpdate: graphUpdate)
        ) { _ in
            resumedAfterAcceptance = true
            return .pure(.finished)
        }
        let reduction: Reduction = .lift(proposal, fallbackTree: fixture.tree) { lifted in
            #expect(lifted != nil)
            switch path {
                case .immediate:
                    return terminal
                case .sequential:
                    return .search(SingleCandidateSearch(), configuration: .standard) { _ in
                        .search(SingleCandidateSearch(candidate: rejected, mutation: nestedProposal.mutation), configuration: .standard) { outcome in
                            #expect(outcome.anyAccepted == false)
                            #expect(outcome.counts.emitted == 1)
                            return terminal
                        }
                    }
                case .proposed:
                    return fixture.propose { _ in terminal }
                case .lifted:
                    return .lift(nestedProposal, fallbackTree: fixture.tree) { nested in
                        #expect(nested != nil)
                        return terminal
                    }
                case .failedLift:
                    return .lift(nestedProposal, fallbackTree: fixture.tree, maximumSequenceCount: 0) { nested in
                        #expect(nested == nil)
                        return terminal
                    }
            }
        }

        let result = fixture.run(reduction) { observation in
            if case let .emitted(_, _, .leafValues(changes)) = observation {
                observedChanges.append(contentsOf: changes)
            }
        }

        #expect(result.incumbent.sequence == candidate)
        #expect(result.report.counts.accepted == 1)
        #expect(result.report.counts.emitted == (path == .sequential ? 2 : 1))
        #expect(result.report.anyRequiresRebuild)
        #expect(result.report.acceptedLeafNodeIDs == [fixture.leafNodeID])
        #expect(result.report.searchCounts.isEmpty)
        #expect(resumedAfterAcceptance == false)
        #expect(observedChanges.isEmpty == false)
        #expect(observedChanges.allSatisfy { $0.leafNodeID == fixture.leafNodeID && $0.newValue.bitPattern64 == 4 && $0.mayReshape })
        // Recovery replaces the incumbent but must not apply lifted node IDs to its old graph.
        guard case let .chooseBits(metadata) = result.graph.nodes[fixture.leafNodeID].kind else {
            Issue.record("The incumbent graph must retain its integer leaf")
            return
        }
        #expect(metadata.value.bitPattern64 == 5)
    }

    @Test("Only searches in the incumbent graph export knowledge, independent of propose nesting", arguments: [false, true], [false, true])
    func reportOwnership(lifted: Bool, proposed: Bool) throws {
        let fixture = try LiftFixture()
        let proposal = try fixture.proposal(value: 4)
        var finished = 0
        let search: Reduction = .search(KnowledgeSearch(nodeID: fixture.leafNodeID, onFinish: { finished += 1 }), configuration: .standard)
        let attempt: Reduction = lifted
            ? .lift(proposal, fallbackTree: fixture.tree) { _ in search }
            : search
        let reduction: Reduction = proposed ? fixture.propose { _ in attempt } : attempt

        let result = fixture.run(reduction)

        #expect(finished == 1)
        #expect(result.report.searchReport.convergenceRecords.isEmpty == lifted)
        #expect(result.report.searchReport.hadUnresolvedReplacement == (lifted == false))
        #expect(result.report.searchCounts.count == (lifted ? 0 : 1))
    }

    @Test("Lift leaves exact decoding an explicit search requirement", arguments: [false, true])
    func decoderRequirement(requiresExact: Bool) throws {
        let fixture = try LiftFixture()
        let proposal = try fixture.proposal(value: 4)
        let candidate = try fixture.sequence(value: 3)
        var selections: [Bool] = []
        let reduction: Reduction = .lift(proposal, fallbackTree: fixture.tree) { _ in
            .search(
                SingleCandidateSearch(candidate: candidate, mutation: .leafValues([])),
                configuration: SearchConfiguration(requiresExactDecoder: requiresExact)
            )
        }

        let result = fixture.run(reduction) { observation in
            if case let .decoderSelected(_, preferExact, _) = observation {
                selections.append(preferExact)
            }
        }

        #expect(selections == [requiresExact])
        #expect(result.report.counts.accepted == 1)
        #expect(result.report.anyRequiresRebuild)
    }

    @Test("A failed first lift leaves subsequent searches in the incumbent graph")
    func failedLiftDoesNotEstablishContext() throws {
        let fixture = try LiftFixture()
        let proposal = try fixture.proposal(value: 4)
        var continued = false
        let reduction: Reduction = .lift(proposal, fallbackTree: fixture.tree, maximumSequenceCount: 0) { lifted in
            #expect(lifted == nil)
            return .search(SingleCandidateSearch(candidate: proposal.prefix.materialized(), mutation: proposal.mutation), configuration: .standard) { _ in
                continued = true
                return .search(KnowledgeSearch(nodeID: fixture.leafNodeID), configuration: .standard)
            }
        }

        let result = fixture.run(reduction)

        #expect(continued)
        #expect(result.report.counts.accepted == 1)
        #expect(result.report.anyRequiresRebuild == false)
        #expect(result.report.searchReport.convergenceRecords[fixture.leafNodeID] != nil)
        #expect(result.report.searchCounts.count == 2)
        guard case let .chooseBits(metadata) = result.graph.nodes[fixture.leafNodeID].kind else {
            Issue.record("The incumbent graph must retain its integer leaf")
            return
        }
        #expect(metadata.value.bitPattern64 == 4)
    }

    @Test("A suspended lifted attempt does not change its sibling's search context")
    func siblingsAreIndependent() throws {
        let fixture = try LiftFixture()
        let liftedProposal = try fixture.proposal(value: 4)
        let rejected = try fixture.sequence(value: 6)
        let alsoRejected = try fixture.sequence(value: 7)
        let ordinaryProposal = try fixture.proposal(value: 3)
        var ordinaryContinued = false
        let reduction = fixture.propose(count: 2) { index in
            if index == 0 {
                return .lift(liftedProposal, fallbackTree: fixture.tree) { _ in
                    .search(SingleCandidateSearch(candidate: rejected, mutation: .leafValues([])), configuration: .standard) { _ in
                        .search(SingleCandidateSearch(candidate: alsoRejected, mutation: .leafValues([])), configuration: .standard)
                    }
                }
            }
            return .search(SingleCandidateSearch(candidate: ordinaryProposal.prefix.materialized(), mutation: ordinaryProposal.mutation), configuration: .standard) { _ in
                ordinaryContinued = true
                return .search(KnowledgeSearch(nodeID: fixture.leafNodeID), configuration: .standard)
            }
        }

        let result = fixture.run(reduction)

        #expect(ordinaryContinued)
        #expect(result.report.counts.emitted == 3)
        #expect(result.report.counts.accepted == 1)
        #expect(result.report.anyRequiresRebuild == false)
        #expect(result.report.searchReport.convergenceRecords[fixture.leafNodeID] != nil)
        #expect(result.report.searchCounts.count == 2)
    }
}

/// A bounded integer with an always-failing property, so only ordering can reject a decoded candidate.
private struct LiftFixture {
    let generator = Gen.choose(in: UInt64(0) ... 100)
    let tree: ChoiceTree
    let graph: ChoiceGraph
    let base: ChoiceSequence
    let leafNodeID: Int

    init() throws {
        tree = try #require(try Interpreters.reflect(generator, with: 5))
        graph = ChoiceGraph.build(from: tree)
        base = ChoiceSequence(tree)
        leafNodeID = try #require(graph.leafNodes.first)
    }

    func sequence(value: UInt64) throws -> ChoiceSequence {
        try ChoiceSequence(#require(try Interpreters.reflect(generator, with: value)))
    }

    func proposal(value: UInt64, nodeID: Int? = nil) throws -> LiftProposal {
        try LiftProposal(prefix: .init(sequence(value: value)), mutation: .leafValues([
            LeafChange(leafNodeID: nodeID ?? leafNodeID, newValue: ChoiceValue(value, tag: .uint64), mayReshape: false),
        ]))
    }

    func propose(count: Int = 1, then build: @escaping (Int) -> Reduction) -> Reduction {
        .propose(
            { IndexedProposals(base: base, count: count) },
            configuration: ChoiceConfiguration(probesPerAttemptTurn: nil, constructedAttemptLimit: nil, totalProbeCap: 0),
            then: { proposal in build(Int(proposal.prefix.value(at: 0)!.choice.bitPattern64)) }
        )
    }

    func run(_ reduction: Reduction, observer: ((ProbeObservation) -> Void)? = nil) -> Reducer.Result {
        Reducer.reduce(reduction, context: Reducer.Context(
            incumbent: Counterexample(sequence: base, tree: tree, output: UInt64(5)),
            incumbentHash: ZobristHash.hash(of: base),
            graph: graph,
            rejectCache: ProbeCache(),
            decoder: ReductionDecoder(generator: generator.erase(), property: { _ in false }, probeWrapper: nil, hasBind: false),
            encoder: ValueSearchEncoder.self,
            observer: observer
        ))
    }
}

/// Labels proposals by index so tests can distinguish siblings without shared mutable cursors.
private struct IndexedProposals: ProposalCursor {
    let base: ChoiceSequence
    let count: Int
    var index = 0

    mutating func next() -> LiftProposal? {
        guard index < count else {
            return nil
        }
        var buffer = base
        buffer[0] = buffer[0].withBitPattern(UInt64(index))
        index += 1
        return LiftProposal(prefix: .init(buffer), mutation: .leafValues([]))
    }
}

/// Returns graph-specific knowledge without emitting a candidate, exposing report ownership independently of acceptance.
private struct KnowledgeSearch: ReductionSearch {
    let nodeID: Int
    var onFinish: () -> Void = {}

    mutating func next(_: SearchFeedback, into _: inout ChoiceSequence) -> ReductionCandidate? {
        nil
    }

    consuming func finish(pending _: SearchFeedback) -> SearchReport {
        onFinish()
        return SearchReport(
            convergenceRecords: [nodeID: ConvergedOrigin(bound: 2, signal: .monotoneConvergence, configuration: .binarySearchSemanticSimplest, cycle: 0)],
            hadUnresolvedReplacement: true
        )
    }
}
