import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("GraphComposedEncoder")
struct GraphComposedEncoderTests {
    @Test("Failed engine lifts are counted without invoking the downstream factory")
    func failedEngineLiftsAreCounted() throws {
        let scope = try #require(singleLeafScope(value: 100))
        let pool = CompositionBuildPool(capacity: 3)
        var recordedAttempts = 0
        var recordedFailures = 0
        var composed = GraphComposedEncoder(
            name: .composed,
            makeProposals: { scope in
                rejectedLeafProposals(scope: scope)
            },
            policy: CompositionPolicy(
                stageBudget: 1,
                chainLimits: chainLimits(maxBuildsPerStart: 3, buildPool: pool)
            ),
            lift: { _, _ in nil },
            recordLiftAttempt: { recordedAttempts += 1 },
            recordBuild: { build in
                switch build {
                    case .failed(.materializationFailed):
                        recordedFailures += 1
                    default:
                        Issue.record("Expected a failed lift")
                }
            },
            downstreamFactory: { _, _, _ in
                Issue.record("A failed lift must not invoke the factory")
                return .failed(.bindNotFound)
            }
        )
        composed.start(scope: scope)
        #expect(drainCandidates(of: &composed, sequence: scope.baseSequence).isEmpty)
        #expect(recordedAttempts == 3)
        #expect(recordedFailures == 3)
        #expect(composed.ledger.attempts == 3)
        #expect(composed.ledger.constructedStages == 0)
        #expect(composed.ledger.emittedProbes == 0)
        #expect(pool.remaining == 0)
    }

    @Test("Each start builds proposals from that scope and resets pass-local work")
    func proposalsFollowEachStart() throws {
        let first = try #require(singleLeafScope(value: 100))
        let second = try #require(singleLeafScope(value: 40))
        var starts: [ChoiceSequence] = []
        var prefixes: [ChoiceSequence] = []
        var encoder = GraphComposedEncoder(
            name: .composed,
            makeProposals: { scope in
                starts.append(scope.baseSequence)
                return rejectedLeafProposals(scope: scope)
            },
            lift: { prefix, _ in
                prefixes.append(prefix)
                return nil
            },
            downstreamFactory: { _, _, _ in
                Issue.record("A failed lift must not build a stage")
                return .failed(.bindNotFound)
            }
        )
        var buffer = first.baseSequence
        #expect(encoder.nextProbe(into: &buffer, lastAccepted: false) == nil)
        #expect(starts.isEmpty)
        encoder.start(scope: first)
        #expect(encoder.nextProbe(into: &buffer, lastAccepted: false) == nil)
        #expect(prefixes.first == ChoiceSequence(ChoiceTree.group([.uint64(50, in: 0 ... 1000)])))
        #expect(encoder.ledger.attempts == prefixes.count)

        prefixes = []
        encoder.start(scope: second)
        #expect(encoder.ledger.attempts == 0)
        #expect(encoder.nextProbe(into: &buffer, lastAccepted: false) == nil)
        #expect(prefixes.first == ChoiceSequence(ChoiceTree.group([.uint64(20, in: 0 ... 1000)])))
        #expect(encoder.ledger.attempts == prefixes.count)
        #expect(starts == [first.baseSequence, second.baseSequence])
    }

    @Test("Each start captures its parsed scope in the downstream factory")
    func downstreamFactoryFollowsEachStart() throws {
        let first = try #require(singleLeafScope(value: 100))
        let second = try #require(singleLeafScope(value: 40))
        var captures: [ChoiceSequence] = []
        var encoder = GraphComposedEncoder(
            name: .composed,
            makeProposals: { scope in
                guard let source = rejectedLeafProposals(scope: scope) else {
                    return nil
                }
                let captured = scope.baseSequence
                return (
                    source: source,
                    downstreamFactory: { proposal, lifted, parent in
                        captures.append(captured)
                        return binaryLeafStage(proposal, lifted: lifted, parent: parent)
                    }
                )
            },
            policy: CompositionPolicy(stageBudget: 1),
            lift: liftLeafProposal
        )
        for scope in [first, second] {
            encoder.start(scope: scope)
            #expect(drainCandidates(of: &encoder, sequence: scope.baseSequence).isEmpty == false)
        }
        #expect(captures == [first.baseSequence, second.baseSequence])
    }

    @Test("Every shared build failure has a diagnostic outcome")
    func buildFailureMappingIsTotal() {
        let failures: [(DownstreamBuildFailure, BoundValueBuildOutcome)] = [
            (.materializationFailed, .materializationFailed),
            (.liftedTooLong, .liftedTooLong),
            (.bindNotFound, .bindNotFound),
            (.noDownstreamLeaves, .noDownstreamLeaves),
        ]
        let tally = BoundValueBuildTally()
        for (failure, outcome) in failures {
            tally.record(.single, build: .failed(failure))
            #expect(tally.counts[BoundValueBuildRecord(stage: .single, outcome: outcome)] == 1)
        }
        #expect(tally.counts.count == failures.count)
        #expect(tally.total == 0)
    }

    // MARK: - Upstream × Downstream Iteration

    @Test("Composition emits downstream probes for each upstream probe")
    func downstreamPerUpstream() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(10 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var composed = GraphComposedEncoder(
            name: .composed,
            makeProposals: rejectedLeafProposals,
            policy: CompositionPolicy(stageBudget: 100),
            lift: liftLeafProposal,
            downstreamFactory: binaryLeafStage
        )

        composed.start(scope: scope)
        var probeCount = 0
        var buffer = sequence
        while composed.nextProbe(into: &buffer, lastAccepted: false) != nil {
            probeCount += 1
        }

        #expect(probeCount > 5, "Composition of two binary-search encoders over 0...100 should emit more than 5 probes")
    }

    @Test("Composition can build another composition downstream")
    func recursiveDownstreamComposition() throws {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(10 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var downstreamBuildCount = 0
        var nestedScopes: [EncoderInput] = []
        var composed = GraphComposedEncoder(
            name: .composed,
            makeProposals: rejectedLeafProposals,
            policy: CompositionPolicy(stageBudget: 2),
            lift: liftLeafProposal,
            downstreamFactory: { _, lifted, parent in
                downstreamBuildCount += 1
                let nestedScope = liftedLeafScope(lifted, parent: parent)
                nestedScopes.append(nestedScope)
                return .stage(encoder: .composed(nestedComposition()), scope: nestedScope)
            }
        )

        composed.start(scope: scope)
        var buffer = sequence
        guard let mutation = composed.nextProbe(into: &buffer, lastAccepted: false) else {
            Issue.record("Expected a recursively composed probe")
            return
        }

        #expect(downstreamBuildCount == 1)
        guard case let .leafValues(changes) = mutation else {
            Issue.record("Expected leafValues mutation, got \(mutation)")
            return
        }
        #expect(changes.count == 1)
        #expect(changes[0].mayReshape)

        var emittedCandidates = [buffer]
        while composed.nextProbe(into: &buffer, lastAccepted: false) != nil {
            emittedCandidates.append(buffer)
        }
        let firstNestedScope = try #require(nestedScopes.first)
        var standaloneNested = nestedComposition()
        standaloneNested.start(scope: firstNestedScope)
        let nestedCandidates = drainCandidates(of: &standaloneNested, sequence: firstNestedScope.baseSequence)
        #expect(nestedCandidates.isEmpty == false)
        #expect(Array(emittedCandidates.prefix(nestedCandidates.count)) == nestedCandidates)
    }

    // MARK: - Stage Turns

    @Test("Each stage emits one turn of probes before the next stage starts, and suspended stages resume oldest first")
    func stageTurnsRotateStages() throws {
        let grouped = try stageProbes(probesPerStageTurn: nil)
        let interleaved = try stageProbes(probesPerStageTurn: 2)

        var stages: [UInt64] = []
        for probe in grouped where stages.contains(probe.stage) == false {
            stages.append(probe.stage)
        }
        try #require(stages.count == 3)
        let first = stages[0]
        let second = stages[1]
        let third = stages[2]
        try #require(grouped.count(where: { $0.stage == first }) >= 4)

        #expect(interleaved.prefix(6).map(\.stage) == [first, first, second, second, third, third])
        #expect(interleaved.dropFirst(6).prefix(2).map(\.stage) == [first, first])
        #expect(longestRun(of: interleaved.map(\.stage)) <= 2)
        for stage in stages {
            #expect(
                interleaved.filter { $0.stage == stage }.map(\.candidate)
                    == grouped.filter { $0.stage == stage }.map(\.candidate),
                "Stage \(stage) must emit the same probes in the same order with or without turns"
            )
        }
    }

    // MARK: - Budget Enforcement

    @Test("Composition stops pulling upstream after budget is exhausted")
    func budgetEnforcement() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(50 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        let unlimitedProbes = drainProbes(
            scope: scope,
            sequence: sequence,
            upstreamBudget: 100
        )

        let limitedProbes = drainProbes(
            scope: scope,
            sequence: sequence,
            upstreamBudget: 1
        )

        #expect(limitedProbes < unlimitedProbes, "Budget=1 should emit fewer probes than budget=100")
        #expect(limitedProbes > 0, "Budget=1 should still emit at least one probe")
    }

    // MARK: - Total Probe Cap

    @Test("Total probe cap stops emission at exactly the cap; zero means unlimited")
    func totalProbeCapBinds() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(50 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        let cap = 3
        let uncappedProbes = drainProbes(
            scope: scope,
            sequence: sequence,
            upstreamBudget: 100
        )
        #expect(uncappedProbes > cap, "The uncapped composition must emit more than the cap for the capped comparison to be meaningful")

        let cappedProbes = drainProbes(
            scope: scope,
            sequence: sequence,
            upstreamBudget: 100,
            totalProbeCap: cap
        )
        #expect(cappedProbes == cap, "A capped composition should emit exactly the cap when the uncapped run exceeds it")
    }

    // MARK: - Build Limits

    @Test("A stage's per-start build limit counts builds that return nil")
    func perStartBuildLimitCountsFailedBuilds() throws {
        let scope = try #require(singleLeafScope(value: 100))
        var builderCalls = 0
        var composed = GraphComposedEncoder(
            name: .composed,
            makeProposals: rejectedLeafProposals,
            policy: CompositionPolicy(stageBudget: 100, chainLimits: chainLimits(maxBuildsPerStart: 3)),
            lift: liftLeafProposal,
            downstreamFactory: { _, _, _ in
                builderCalls += 1
                return .failed(.bindNotFound)
            }
        )

        composed.start(scope: scope)
        let probes = drainCandidates(of: &composed, sequence: scope.baseSequence)

        #expect(probes.isEmpty)
        #expect(builderCalls == 3)
    }

    @Test("A shared build pool bounds builder calls across nested compositions, including stages whose search emits nothing")
    func sharedBuildPoolBoundsNestedBuilds() throws {
        let scope = try #require(singleLeafScope(value: 100))
        let pool = CompositionBuildPool(capacity: 5)
        var builderCalls = 0
        var composed = GraphComposedEncoder(
            name: .composed,
            makeProposals: rejectedLeafProposals,
            policy: CompositionPolicy(stageBudget: 100, chainLimits: chainLimits(buildPool: pool)),
            lift: liftLeafProposal,
            downstreamFactory: { _, lifted, parent in
                builderCalls += 1
                let nestedScope = liftedLeafScope(lifted, parent: parent)
                let emptyNested = GraphComposedEncoder(
                    name: .composed,
                    makeProposals: rejectedLeafProposals,
                    policy: CompositionPolicy(stageBudget: 100, chainLimits: chainLimits(buildPool: pool)),
                    lift: liftLeafProposal,
                    downstreamFactory: { _, _, _ in
                        builderCalls += 1
                        return .failed(.bindNotFound)
                    }
                )
                return .stage(encoder: .composed(emptyNested), scope: nestedScope)
            }
        )

        composed.start(scope: scope)
        let probes = drainCandidates(of: &composed, sequence: scope.baseSequence)

        #expect(probes.isEmpty)
        #expect(builderCalls == 5)
        #expect(pool.remaining == 0)
    }

    @Test("Per-start build limits drop by a quarter per nesting level and never reach zero")
    func nestedChainBuildsPerStartDecay() {
        let limits = (0 ..< 8).map { ChoiceGraphScheduler.nestedChainBuildsPerStart(depth: $0) }
        #expect(limits == [64, 48, 36, 27, 20, 15, 11, 8])
        #expect(ChoiceGraphScheduler.nestedChainBuildsPerStart(depth: 40) == 1)
    }

    @Test("Chain build pools hold at the base through three stages, quadruple per stage beyond, and stop at the maximum")
    func nestedChainBuildPoolGrowth() {
        let pools = (1 ... 6).map { ChoiceGraphScheduler.nestedChainBuildPool(chainLength: $0) }
        #expect(pools == [128, 128, 128, 512, 1024, 1024])
        #expect(ChoiceGraphScheduler.nestedChainBuildPool(chainLength: 40) == ChoiceGraphScheduler.nestedChainMaxBuildPool)
    }

    @Test("A nested bind chain's composition stays within its shared build pool on one probe request")
    func nestedBindChainRespectsBuildPool() throws {
        let continuationCalls = ContinuationCounter()
        let chainDepth = 6
        let generator = nestedBindChain(depth: chainDepth, continuationCalls: continuationCalls)
        var (encoder, scope) = try boundValueComposition(
            of: generator,
            upstreamBudget: 4,
            totalProbeCap: 1
        )
        encoder.start(scope: scope)
        continuationCalls.value = 0

        var candidate = scope.baseSequence
        _ = encoder.nextProbe(into: &candidate, lastAccepted: false)

        // Each build materializes the whole chain once, calling every bind's continuation.
        #expect(continuationCalls.value <= ChoiceGraphScheduler.nestedChainBuildPool(chainLength: chainDepth) * chainDepth)
    }

    @Test("The build tally counts one entry per generator materialization at every nesting level")
    func buildTallyCountsEveryLiftMaterialization() throws {
        let rootContinuationCalls = ContinuationCounter()
        let generator = nestedBindChain(
            depth: 3,
            continuationCalls: ContinuationCounter(),
            rootContinuationCalls: rootContinuationCalls
        )
        let buildTally = BoundValueBuildTally()
        var (encoder, scope) = try boundValueComposition(
            of: generator,
            upstreamBudget: 4,
            buildTally: buildTally
        )
        encoder.start(scope: scope)
        rootContinuationCalls.value = 0

        var candidate = scope.baseSequence
        while encoder.nextProbe(into: &candidate, lastAccepted: false) != nil {}

        let stagesThatBuilt = Set(buildTally.counts.keys.map(\.stage))
        #expect(stagesThatBuilt.contains(.chainRoot))
        #expect(stagesThatBuilt.contains(.chainTail))
        // Every materialization enters the root bind's continuation exactly once.
        #expect(buildTally.total == rootContinuationCalls.value)
    }

    // MARK: - Bound Value Covering

    @Test("Covering search changes only the scope's leaves, even when other leaves sit between them")
    func coveringChangesOnlyScopeLeaves() throws {
        try exhaustCheck(coveringScopeGen, maxIterations: 500) { entries in
            let fixture = GraphFixture(.uint64Zip(entries.map(\.value), in: 0 ... 3))
            let leafNodeIDs = fixture.graph.leafNodes
            let scopedNodeIDs = zip(leafNodeIDs, entries).filter { $0.1.isInScope }.map(\.0)
            let fixedPositions = zip(leafNodeIDs, entries).compactMap { nodeID, entry in
                entry.isInScope ? nil : fixture.graph.nodes[nodeID].positionRange?.lowerBound
            }
            let scope = EncoderInput(
                transformation: GraphTransformation(
                    operation: .minimize(.valueLeaves(ValueMinimizationScope(
                        leaves: scopedNodeIDs.map { LeafEntry(nodeID: $0, mayReshapeOnAcceptance: false) },
                        batchZeroEligible: false
                    ))),
                    priority: DispatchPriority(structuralBenefit: 0, valueBenefit: 0, reductionMagnitude: 0, estimatedCost: 1)
                ),
                baseSequence: fixture.sequence,
                tree: fixture.tree,
                graph: fixture.graph,
                warmStartRecords: [:]
            )
            var encoder = GraphBoundValueCoveringEncoder()
            encoder.start(scope: scope)

            var candidate = fixture.sequence
            while encoder.nextProbe(into: &candidate, lastAccepted: false) != nil {
                for position in fixedPositions where candidate[position] != fixture.sequence[position] {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Lift Failure

    @Test("Failed lifts are skipped without counting against budget")
    func liftFailureSkipped() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(20 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var liftCallCount = 0
        var composed = GraphComposedEncoder(
            name: .composed,
            makeProposals: rejectedLeafProposals,
            policy: CompositionPolicy(stageBudget: 2),
            lift: { prefix, fallbackTree in
                liftCallCount += 1
                guard liftCallCount % 2 != 0 else {
                    return nil
                }
                return liftLeafProposal(prefix, fallbackTree)
            },
            downstreamFactory: binaryLeafStage
        )

        composed.start(scope: scope)
        var probeCount = 0
        var buffer = sequence
        while composed.nextProbe(into: &buffer, lastAccepted: false) != nil {
            probeCount += 1
        }

        #expect(liftCallCount > 2, "Failed lifts should cause additional upstream pulls beyond the budget count")
        #expect(probeCount > 0, "Should still emit probes from successful lifts")
    }

    // MARK: - Mutation Wrapping

    @Test("Composition wraps downstream mutation with mayReshape true")
    func mutationWrapping() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(30 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var composed = GraphComposedEncoder(
            name: .composed,
            makeProposals: rejectedLeafProposals,
            policy: CompositionPolicy(stageBudget: 5),
            lift: liftLeafProposal,
            downstreamFactory: binaryLeafStage
        )

        composed.start(scope: scope)
        var buffer = sequence
        guard let mutation = composed.nextProbe(into: &buffer, lastAccepted: false) else {
            Issue.record("Expected at least one probe")
            return
        }

        guard case let .leafValues(changes) = mutation else {
            Issue.record("Expected leafValues mutation, got \(mutation)")
            return
        }
        #expect(changes.isEmpty == false)
        let allReshape = changes.allSatisfy(\.mayReshape)
        #expect(allReshape, "Composed mutations should have mayReshape set to true")
    }

    // MARK: - refreshState Aborts In-Flight

    @Test("refreshState resets composition so no further probes are emitted")
    func refreshStateResetsComposition() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(40 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var composed = GraphComposedEncoder(
            name: .composed,
            makeProposals: rejectedLeafProposals,
            policy: CompositionPolicy(stageBudget: 10),
            lift: liftLeafProposal,
            downstreamFactory: binaryLeafStage
        )

        composed.start(scope: scope)
        var buffer = sequence
        _ = composed.nextProbe(into: &buffer, lastAccepted: false)

        composed.refreshState(graph: graph, sequence: sequence)
        let afterRefresh = composed.nextProbe(into: &buffer, lastAccepted: false)
        #expect(afterRefresh == nil, "No probes should be emitted after refreshState")
    }

    // MARK: - Convergence Records

    @Test("Fixed proposals do not inherit an adaptive encoder's convergence records")
    func adaptiveConvergenceNotTransferred() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(10 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var composed = GraphComposedEncoder(
            name: .composed,
            makeProposals: rejectedLeafProposals,
            policy: CompositionPolicy(stageBudget: 100),
            lift: liftLeafProposal,
            downstreamFactory: binaryLeafStage
        )

        composed.start(scope: scope)
        var buffer = sequence
        var accepted = false
        while composed.nextProbe(into: &buffer, lastAccepted: accepted) != nil {
            accepted = true
        }
        composed.flushPartialConvergence()

        var adaptive = GraphValueEncoder()
        adaptive.start(scope: scope)
        while adaptive.nextProbe(into: &buffer, lastAccepted: false) != nil {}
        adaptive.flushPartialConvergence()
        #expect(adaptive.convergenceRecords.isEmpty == false, "The adaptive oracle produces convergence records")
        #expect(composed.convergenceRecords.isEmpty, "Fixed proposals have no acceptance-dependent convergence")
    }
}

// MARK: - Helpers

private func drainProbes(
    scope: EncoderInput,
    sequence: ChoiceSequence,
    upstreamBudget: Int,
    totalProbeCap: Int = 0
) -> Int {
    var composed = GraphComposedEncoder(
        name: .composed,
        makeProposals: rejectedLeafProposals,
        policy: CompositionPolicy(stageBudget: upstreamBudget, totalProbeCap: totalProbeCap),
        lift: liftLeafProposal,
        downstreamFactory: binaryLeafStage
    )

    composed.start(scope: scope)
    var count = 0
    var buffer = sequence
    while composed.nextProbe(into: &buffer, lastAccepted: false) != nil {
        count += 1
    }
    return count
}

private func minimizationScope(
    tree: ChoiceTree,
    graph: ChoiceGraph,
    sequence: ChoiceSequence
) -> EncoderInput? {
    let scopes = MinimizationQuery.build(graph: graph)
    guard let firstScope = scopes.first else { return nil }
    let transformation = GraphTransformation(
        operation: .minimize(firstScope),
        priority: DispatchPriority(
            structuralBenefit: 0,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 10
        )
    )
    return EncoderInput(
        transformation: transformation,
        baseSequence: sequence,
        tree: tree,
        graph: graph,
        warmStartRecords: [:]
    )
}

/// One leaf of a covering fixture: its value, and whether the covering scope includes it.
private struct CoveringScopeEntry: CustomStringConvertible {
    let value: UInt64
    let isInScope: Bool

    var description: String {
        "\(value)\(isInScope ? "" : " (fixed)")"
    }
}

/// Three to six leaves over `0...3`, each in or out of the covering scope, so out-of-scope leaves regularly fall between in-scope ones.
private let coveringScopeGen: Generator<[CoveringScopeEntry]> = Gen.arrayOf(
    Gen.zip(Gen.choose(in: UInt64(0) ... 3), Gen.choose(in: UInt64(0) ... 1))
        .map { value, flag in CoveringScopeEntry(value: value, isInScope: flag == 1) },
    within: 3 ... 6
)

/// A composition over the scope's single leaf whose downstream re-searches the lifted candidate.
private func nestedComposition() -> GraphComposedEncoder {
    GraphComposedEncoder(
        name: .composed,
        makeProposals: rejectedLeafProposals,
        policy: CompositionPolicy(stageBudget: 2),
        lift: liftLeafProposal,
        downstreamFactory: binaryLeafStage
    )
}

private func drainCandidates(
    of composed: inout GraphComposedEncoder,
    sequence: ChoiceSequence
) -> [ChoiceSequence] {
    var candidates: [ChoiceSequence] = []
    var buffer = sequence
    while composed.nextProbe(into: &buffer, lastAccepted: false) != nil {
        candidates.append(buffer)
    }
    return candidates
}

/// Drains a three-stage composition over one leaf at 100 in `0...1000`. Each stage's downstream binary search starts from that stage's upstream value, so stages emit different probes; the stage is identified by the upstream value its wrapped mutation carries.
private func stageProbes(probesPerStageTurn: Int?) throws -> [(stage: UInt64, candidate: ChoiceSequence)] {
    let scope = try #require(singleLeafScope(value: 100))
    var composed = GraphComposedEncoder(
        name: .composed,
        makeProposals: rejectedLeafProposals,
        policy: CompositionPolicy(
            stageBudget: 3,
            chainLimits: probesPerStageTurn.map { chainLimits(probesPerStageTurn: $0) }
        ),
        lift: liftLeafProposal,
        downstreamFactory: binaryLeafStage
    )

    composed.start(scope: scope)
    var probes: [(stage: UInt64, candidate: ChoiceSequence)] = []
    var buffer = scope.baseSequence
    while let mutation = composed.nextProbe(into: &buffer, lastAccepted: false) {
        guard case let .leafValues(changes) = mutation, let change = changes.first else {
            Issue.record("Expected a leafValues mutation, got \(mutation)")
            return probes
        }
        probes.append((change.newValue.bitPattern64, buffer))
    }
    return probes
}

/// Chain limits that leave every limit not named unbounded.
private func chainLimits(
    probesPerStageTurn: Int = .max,
    maxBuildsPerStart: Int = .max,
    buildPool: CompositionBuildPool = CompositionBuildPool(capacity: .max)
) -> NestedChainLimits {
    NestedChainLimits(
        probesPerStageTurn: probesPerStageTurn,
        maxBuildsPerStart: maxBuildsPerStart,
        buildPool: buildPool
    )
}

private func singleLeafScope(value: UInt64) -> EncoderInput? {
    let tree = ChoiceTree.group([
        .choice(ChoiceValue(value, tag: .uint64), .init(validRange: 0 ... 1000, isRangeExplicit: true)),
    ])
    return minimizationScope(
        tree: tree,
        graph: ChoiceGraph.build(from: tree),
        sequence: ChoiceSequence.flatten(tree)
    )
}

private func longestRun(of stages: [UInt64]) -> Int {
    var longest = 0
    var current = 0
    var previous: UInt64?
    for stage in stages {
        current = stage == previous ? current + 1 : 1
        longest = max(longest, current)
        previous = stage
    }
    return longest
}

/// A chain of `depth` nested binds, each bound value drawn from `0...3`, ending in a constant leaf. Every continuation call is counted in `continuationCalls`, and the outermost bind's calls also in `rootContinuationCalls`.
private func nestedBindChain(
    depth: Int,
    continuationCalls: ContinuationCounter,
    rootContinuationCalls: ContinuationCounter? = nil
) -> AnyGenerator {
    guard depth > 0 else {
        return Gen.choose(in: UInt64(0) ... 0).erase()
    }
    let next = nestedBindChain(depth: depth - 1, continuationCalls: continuationCalls)
    return .impure(
        operation: .transform(
            kind: .bind(
                fingerprint: UInt64(depth),
                forward: { _ in
                    continuationCalls.value += 1
                    rootContinuationCalls?.value += 1
                    return next
                },
                backward: { _ in UInt64(1) },
                inputType: UInt64.self,
                outputType: UInt64.self
            ),
            inner: Gen.choose(in: UInt64(0) ... 3).erase()
        ),
        continuation: { .pure($0) }
    )
}

/// The bound value composition the scheduler dispatches for the outermost bind of `generator`, reflected at zero, with the scope to start it on.
private func boundValueComposition(
    of generator: AnyGenerator,
    upstreamBudget: Int,
    totalProbeCap: Int = 0,
    buildTally: BoundValueBuildTally = BoundValueBuildTally()
) throws -> (encoder: EncoderDispatch, scope: EncoderInput) {
    let tree = try #require(try Interpreters.reflect(generator, with: UInt64(0)))
    let graph = ChoiceGraph.build(from: tree)
    let sequence = ChoiceSequence.flatten(tree)
    let bindNodeID = try #require(graph.liveNodeIDs.first { nodeID in
        if case .bind = graph.nodes[nodeID].kind { true } else { false }
    })
    guard case let .bind(metadata) = graph.nodes[bindNodeID].kind else {
        throw BoundValueCompositionFixtureError.missingBind
    }
    let bindScope = BoundValueScope(
        bindNodeID: bindNodeID,
        upstreamLeafNodeID: graph.nodes[bindNodeID].children[metadata.innerChildIndex],
        downstreamNodeIDs: Array(graph.leafNodes.dropFirst()),
        boundSubtreeSize: sequence.count
    )
    let scope = EncoderInput(
        transformation: GraphTransformation(
            operation: .minimize(.boundValue(bindScope)),
            priority: DispatchPriority(structuralBenefit: 0, valueBenefit: 0, reductionMagnitude: 0, estimatedCost: 1)
        ),
        baseSequence: sequence,
        tree: tree,
        graph: graph,
        warmStartRecords: [:]
    )
    let encoder = ChoiceGraphScheduler.makeBoundValueComposition(
        bindScope: bindScope,
        scope: scope,
        graph: graph,
        gen: generator,
        upstreamBudget: upstreamBudget,
        totalProbeCap: totalProbeCap,
        buildTally: buildTally
    )
    return (encoder, scope)
}

private enum BoundValueCompositionFixtureError: Error {
    case missingBind
}

private final class ContinuationCounter {
    var value = 0
}
