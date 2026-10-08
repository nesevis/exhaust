import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Cooperative reducer deadline accounting")
struct ReductionDeadlineTests {
    @Test("Expired deadlines stop every machine phase before starting work", arguments: [
        ReductionMachine.Phase.beginCycle,
        .buildSources,
        .dispatching,
        .endCycle,
        .postCycle(remaining: [.confirmConvergence, .relationPass, .improvingPivots, .pairwiseNumericPass, .excursion]),
        .checkTermination,
        .reorderPass,
    ])
    func expiresBeforePhase(phase: ReductionMachine.Phase) throws {
        let clock = DeadlineTestClock()
        var machine = try scalarMachine(clock: clock) { _ in
            Issue.record("An expired phase must not call the property")
            return false
        }
        machine.phase = phase
        clock.expire()
        let transition = machine.next()
        guard case .terminated = transition else {
            Issue.record("Expiry must terminate the machine")
            return
        }
        #expect(machine.stats.reductionWasCapped)
        #expect(machine.stats.reductionProbes == 0)
        #expect(machine.passCounter == 0)
        #expect(machine.output as? UInt64 == 37)
        #expect(try machine.next() == nil)
    }

    @Test("Expiry during a property preserves the accepted result and reports the pass exactly once", arguments: [false, true], [false, true])
    func expiresDuringDecode(accepted: Bool, collectStats: Bool) throws {
        let clock = DeadlineTestClock()
        var propertyCalls = 0
        var machine = try scalarMachine(clock: clock, collectStats: collectStats) { _ in
            propertyCalls += 1
            clock.expire()
            return accepted == false
        }
        _ = try complete(&machine)
        #expect(propertyCalls == 1)
        #expect(machine.passCounter == 1)
        #expect(machine.activeSession == nil)
        #expect(machine.pendingReport == nil)
        #expect(machine.sources.isEmpty)
        #expect(machine.anyAcceptanceEverOccurred == accepted)
        #expect(machine.output as? UInt64 == (accepted ? 0 : 37))
        #expect(ChoiceSequence(machine.tree) == machine.sequence)
        #expect(machine.stats.reductionProbes == (collectStats ? 1 : 0))
        #expect(machine.stats.reductionProbesAccepted == (collectStats && accepted ? 1 : 0))
        #expect(machine.stats.materializationsBySite[.decoder, default: 0] == (collectStats ? (accepted ? 2 : 1) : 0))
        #expect(machine.stats.encoderProbes[.numericReorder] == nil)
        for _ in 0 ..< 3 {
            #expect(try machine.next() == nil)
        }
        #expect(machine.passCounter == 1)
        let result: (outcome: ReductionOutcome<UInt64>, stats: ReductionStats) = machine.typedResult()
        #expect(result.outcome.counterexample?.1 == (accepted ? 0 : 37))
        #expect(result.stats.reductionWasCapped)
        #expect(result.stats.anyAcceptanceEverOccurred == accepted)
    }

    @Test("Expiry between encoding and decoding reports the emitted probe without invoking the property")
    func expiresBeforePendingDecode() throws {
        let clock = DeadlineTestClock()
        var machine = try scalarMachine(clock: clock) { _ in
            Issue.record("A pending probe must not decode after expiry")
            return false
        }
        try advanceToEncodedProbe(&machine)
        #expect(machine.activeSession?.phase == .decode)
        clock.expire()
        _ = machine.next()
        #expect(machine.stats.reductionProbes == 1)
        #expect(machine.stats.reductionProbesAccepted == 0)
        #expect(machine.stats.materializationsBySite[.decoder] == nil)
        #expect(machine.output as? UInt64 == 37)
        #expect(machine.passCounter == 1)
        #expect(machine.stats.reductionWasCapped)
        #expect(try machine.next() == nil)
    }

    @Test("Structural acceptances are reported once on either side of the report boundary", arguments: [false, true])
    func expiresAroundStructuralReport(reportAlreadyApplied: Bool) throws {
        let clock = DeadlineTestClock()
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 0 ... 5)
        var propertyCalls = 0
        var machine = try makeMachine(generator: generator, initialOutput: [UInt64(3), 2, 1], clock: clock, enabledEncoders: [.deletion]) { _ in
            propertyCalls += 1
            return false
        }
        let originalRebuilds = machine.stats.graphStats.fullGraphRebuilds
        var reachedAcceptance = false
        for _ in 0 ..< 100 {
            if case .decoded(_, accepted: true) = machine.next() {
                reachedAcceptance = true
                break
            }
        }
        #expect(reachedAcceptance)
        #expect(machine.activeSession?.anyRequiresRebuild == true)
        if reportAlreadyApplied {
            _ = machine.next()
            #expect(machine.activeSession == nil)
            #expect(machine.pendingReport?.anyRequiresRebuild == true)
        }
        clock.expire()
        _ = machine.next()
        #expect(machine.passCounter == 1)
        #expect(propertyCalls == 1)
        #expect(machine.stats.reductionProbes == 1)
        #expect(machine.stats.reductionProbesAccepted == 1)
        #expect(machine.stats.graphStats.fullGraphRebuilds == originalRebuilds + 1)
        #expect(machine.graph.nodes.count == ChoiceGraph.build(from: machine.tree).nodes.count)
        #expect(ChoiceSequence(machine.tree) == machine.sequence)
        #expect(machine.output as? [UInt64] == [])
        #expect(machine.pendingReport == nil)
        #expect(machine.sources.isEmpty)
        #expect(machine.stats.reductionWasCapped)
        #expect(try machine.next() == nil)
    }

    @Test("Post-cycle relation and numeric passes stop after their first in-flight property", arguments: [false, true], [false, true])
    func postCyclePassesHonorDeadline(numericPass: Bool, accepted: Bool) throws {
        let clock = DeadlineTestClock()
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 2 ... 2)
        let encoder: EncoderName = numericPass ? .pairwiseNumericSearch : .relationSearch
        var propertyCalls = 0
        var machine = try makeMachine(generator: generator, initialOutput: [UInt64(40), 20], clock: clock, enabledEncoders: [encoder]) { _ in
            propertyCalls += 1
            clock.expire()
            return accepted == false
        }
        markStalledLeaves(&machine.graph)
        machine.convergence.deferBindInner = false
        if numericPass {
            #expect(machine.pendingNumericPairs() != nil)
        } else {
            #expect(RelationQuery.build(graph: machine.graph) != nil)
        }
        machine.phase = .postCycle(remaining: [numericPass ? .pairwiseNumericPass : .relationPass, .excursion, .releaseDeferral])
        let initialSequence = machine.sequence
        _ = try complete(&machine)
        #expect(propertyCalls == 1)
        #expect(machine.passCounter == 1)
        #expect(machine.stats.encoderProbes[encoder] == 1)
        #expect(machine.stats.encoderProbesAccepted[encoder] == (accepted ? 1 : 0))
        #expect(machine.sequence.shortLexPrecedes(initialSequence) == accepted)
        #expect(ChoiceSequence(machine.tree) == machine.sequence)
        #expect(machine.stats.reductionWasCapped)
        #expect(machine.deferralReleasedThisCycle == false)
        #expect(machine.stats.encoderProbes[.numericReorder] == nil)
    }

    @Test("Final reordering observes deadlines without rebuilding the final graph", arguments: [false, true])
    func reorderHonorsDeadline(accepted: Bool) throws {
        let clock = DeadlineTestClock()
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 3 ... 3)
        var propertyCalls = 0
        var machine = try makeMachine(generator: generator, initialOutput: [UInt64(3), 2, 1], clock: clock, enabledEncoders: [.numericReorder]) { _ in
            propertyCalls += 1
            clock.expire()
            return accepted == false
        }
        #expect(ReorderingQuery.build(graph: machine.graph) != nil)
        let originalRebuilds = machine.stats.graphStats.fullGraphRebuilds
        machine.phase = .reorderPass
        _ = try complete(&machine)
        #expect(propertyCalls == 1)
        #expect(machine.stats.encoderProbes[.numericReorder] == 1)
        #expect(machine.stats.encoderProbesAccepted[.numericReorder] == (accepted ? 1 : 0))
        #expect(machine.stats.graphStats.fullGraphRebuilds == originalRebuilds)
        #expect(machine.output as? [UInt64] == (accepted ? [1, 2, 3] : [3, 2, 1]))
        #expect(ChoiceSequence(machine.tree) == machine.sequence)
        #expect(machine.stats.reductionWasCapped)
    }

    @Test("Convergence confirmation does not start a gap probe after the first property expires")
    func confirmationStopsBeforeGap() throws {
        let clock = DeadlineTestClock()
        var propertyCalls = 0
        var machine = try scalarMachine(clock: clock, enabledEncoders: [.convergenceConfirmation]) { _ in
            propertyCalls += 1
            clock.expire()
            return true
        }
        markStalledLeaves(&machine.graph)
        machine.phase = .postCycle(remaining: [.confirmConvergence, .relationPass])
        _ = try complete(&machine)
        #expect(propertyCalls == 1)
        #expect(machine.stats.encoderProbes[.convergenceConfirmation] == 1)
        #expect(machine.stats.reductionWasCapped)
        #expect(machine.output as? UInt64 == 37)
    }

    @Test("An expired excursion rolls back its worsening perturbation before preparing exploitation")
    func excursionRestoresCheckpoint() throws {
        let clock = DeadlineTestClock()
        let generator = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 100)),
            (1, Gen.choose(in: UInt64(200) ... 300)),
        ])
        var propertyCalls = 0
        var machine = try makeMachine(generator: generator, initialOutput: UInt64(10), clock: clock, enabledEncoders: [.branchPivot]) { _ in
            propertyCalls += 1
            clock.expire()
            return false
        }
        let checkpoint = machine.sequence
        let originalRebuilds = machine.stats.graphStats.fullGraphRebuilds
        machine.phase = .postCycle(remaining: [.excursion])
        _ = try complete(&machine)
        #expect(propertyCalls == 1)
        #expect(machine.sequence == checkpoint)
        #expect(machine.output as? UInt64 == 10)
        #expect(ChoiceSequence(machine.tree) == checkpoint)
        #expect(machine.stats.graphStats.fullGraphRebuilds == originalRebuilds)
        #expect(machine.passCounter == 0)
        #expect(machine.stats.reductionProbes == 1)
        #expect(machine.anyAccepted == false)
        #expect(machine.stats.reductionWasCapped)
    }

    @Test("An improving pivot accepted at expiry is retained and marked as an acceptance")
    func improvingPivotSurvivesDeadline() throws {
        let clock = DeadlineTestClock()
        let generator = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 100)),
            (1, Gen.choose(in: UInt64(200) ... 300)),
        ])
        var propertyCalls = 0
        var machine = try makeMachine(generator: generator, initialOutput: UInt64(250), clock: clock, enabledEncoders: [.branchPivot]) { _ in
            propertyCalls += 1
            clock.expire()
            return false
        }
        let initialSequence = machine.sequence
        machine.phase = .postCycle(remaining: [.improvingPivots, .excursion])
        _ = try complete(&machine)
        #expect(propertyCalls == 1)
        #expect(machine.sequence.shortLexPrecedes(initialSequence))
        #expect(ChoiceSequence(machine.tree) == machine.sequence)
        #expect(machine.stats.relaxImprovingAcceptances == 1)
        #expect(machine.stats.anyAcceptanceEverOccurred)
        #expect(machine.stats.reductionWasCapped)
    }

    @Test("Improving-pivot preparation and enumeration cannot start a property after expiry", arguments: [0, 1, 2, 3])
    func improvingPivotPreparationBoundary(permittedClockReads: Int) throws {
        let clock = DeadlineTestClock()
        let generator = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 100)),
            (1, Gen.choose(in: UInt64(200) ... 300)),
        ])
        var propertyCalls = 0
        var machine = try makeMachine(generator: generator, initialOutput: UInt64(250), clock: clock, enabledEncoders: [.branchPivot]) { _ in
            propertyCalls += 1
            return false
        }
        let checkpoint = machine.sequence
        let originalMaterializations = machine.stats.totalMaterializations
        clock.permittedReadsBeforeExpiry = permittedClockReads
        let improved = machine.runImprovingPivotPass()
        #expect(improved == false)
        #expect(propertyCalls == 0)
        #expect(machine.sequence == checkpoint)
        #expect(machine.stats.totalMaterializations == originalMaterializations)
        #expect(machine.stats.relaxImprovingProbes == 0)
        #expect(machine.stats.reductionProbes == 0)
        #expect(machine.passCounter == 0)
        #expect(machine.anyAcceptanceEverOccurred == false)
        _ = try complete(&machine)
        #expect(machine.stats.reductionWasCapped)
        #expect(propertyCalls == 0)
        #expect(machine.output as? UInt64 == 250)
    }

    @Test("Unlimited runs do not read the injected deadline clock")
    func zeroDeadlineIsUnlimited() throws {
        let clock = DeadlineTestClock()
        var machine = try scalarMachine(clock: clock, deadline: 0) { _ in false }
        clock.expire()
        _ = try complete(&machine)
        #expect(clock.readCount == 0)
        #expect(machine.stats.reductionWasCapped == false)
        #expect(machine.output as? UInt64 == 0)
    }

    @Test("Session deadlines interrupt cache-only streams between emissions")
    func sessionChecksCacheRejections() throws {
        var state = try scalarState { _ in
            Issue.record("The session must stop before any uncached decode")
            return false
        }
        var rejected = state.sequence
        rejected[0] = rejected[0].withBitPattern(0)
        state.rejectCache.insert(ZobristHash.hash(of: rejected))
        var session = state.makeSession(for: scalarScope(state))
        var checks = 0
        let report = session.runToCompletion(state: &state, deadlineCheck: {
            checks += 1
            return checks > 1
        })
        #expect(report.probeCount == 1)
        #expect(report.cacheHitCount == 1)
        #expect(report.counts.materializationAttempts == 0)
        #expect(state.output as? UInt64 == 37)
        #expect(session.phase == .finished)
    }

    @Test("Session deadlines stop before pending decoding or the first emission", arguments: [0, 1])
    func sessionStopsBeforeDecode(allowedSteps: Int) throws {
        var state = try scalarState { _ in
            Issue.record("The session must not decode after expiry")
            return false
        }
        var session = state.makeSession(for: scalarScope(state))
        var checks = 0
        let report = session.runToCompletion(state: &state, deadlineCheck: {
            checks += 1
            return checks > allowedSteps
        })
        #expect(report.probeCount == allowedSteps)
        #expect(report.counts.materializationAttempts == 0)
        #expect(report.acceptCount == 0)
        #expect(state.output as? UInt64 == 37)
        #expect(session.phase == .finished)
    }
}

// MARK: - Test Helpers

/// Advances only when a test changes time; property closures can expire the budget while a decode is in flight.
private final class DeadlineTestClock {
    private var nanoseconds: UInt64 = 0
    private(set) var readCount = 0
    var permittedReadsBeforeExpiry: Int?

    func read() -> UInt64 {
        readCount += 1
        if let remainingReads = permittedReadsBeforeExpiry {
            if remainingReads == 0 {
                expire()
            } else {
                permittedReadsBeforeExpiry = remainingReads - 1
            }
        }
        return nanoseconds
    }

    func expire() {
        nanoseconds = 100
    }
}

private func scalarMachine(
    clock: DeadlineTestClock,
    collectStats: Bool = true,
    deadline: UInt64 = 100,
    enabledEncoders: Set<EncoderName> = [.valueSearch],
    property: @escaping (UInt64) -> Bool
) throws -> ReductionMachine {
    try makeMachine(generator: Gen.choose(in: UInt64(0) ... 100), initialOutput: UInt64(37), clock: clock, collectStats: collectStats, deadline: deadline, enabledEncoders: enabledEncoders, property: property)
}

/// Reflects the exact counterexample so fixture setup uses the same generator and tree the decoder will replay.
private func makeMachine<Output>(
    generator: Generator<Output>,
    initialOutput: Output,
    clock: DeadlineTestClock,
    collectStats: Bool = true,
    deadline: UInt64 = 100,
    enabledEncoders: Set<EncoderName>,
    property: @escaping (Output) -> Bool
) throws -> ReductionMachine {
    let tree = try #require(try Interpreters.reflect(generator, with: initialOutput))
    return ReductionMachine(
        gen: generator,
        initialTree: tree,
        initialOutput: initialOutput,
        config: Interpreters.ReducerConfiguration(maxStalls: 2, wallClockDeadlineNanoseconds: deadline, enabledEncoders: enabledEncoders),
        collectStats: collectStats,
        currentNanoseconds: clock.read,
        property: property
    )
}

/// Fails deterministically if a fixture loops instead of reaching its cooperative stopping point.
private func complete(_ machine: inout ReductionMachine) throws -> [ReductionMachine.Transition] {
    var transitions: [ReductionMachine.Transition] = []
    for _ in 0 ..< 1000 {
        guard let transition = machine.next() else {
            return transitions
        }
        transitions.append(transition)
    }
    Issue.record("The bounded fixture did not terminate")
    return transitions
}

/// Leaves one emitted probe waiting to decode so the next machine step tests the exact expiry boundary.
private func advanceToEncodedProbe(_ machine: inout ReductionMachine) throws {
    for _ in 0 ..< 100 {
        if case .encoded = machine.next() {
            return
        }
    }
    Issue.record("Expected the fixture to encode a probe")
}

private func markStalledLeaves(_ graph: inout ChoiceGraph) {
    for nodeID in graph.leafNodes {
        guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
            continue
        }
        graph.convergenceStore[nodeID] = ConvergedOrigin(bound: metadata.value.bitPattern64, signal: .monotoneConvergence, configuration: .binarySearchSemanticSimplest, cycle: 0)
    }
}

private func scalarState(property: @escaping (Any) -> Bool) throws -> ProbeSessionFixtureState {
    let generator = Gen.choose(in: UInt64(0) ... 100)
    let tree = try #require(try Interpreters.reflect(generator, with: UInt64(37)))
    return ProbeSessionFixtureState(sequence: ChoiceSequence(tree), tree: tree, output: UInt64(37), graph: ChoiceGraph.build(from: tree), gen: generator.erase(), property: property)
}

private func scalarScope(_ state: ProbeSessionFixtureState) -> EncoderInput {
    let scope = ValueMinimizationScope(leaves: state.graph.leafNodes.map { LeafEntry(nodeID: $0) }, batchZeroEligible: true)
    return EncoderInput(transformation: GraphTransformation(operation: .minimize(.valueLeaves(scope)), priority: .zeroBenefit), baseSequence: state.sequence, tree: state.tree, graph: state.graph, warmStartRecords: [:])
}
