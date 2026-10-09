import Testing
@testable import ExhaustCore

@Suite("Nested excursion stepping")
struct ExcursionSteppingTests {
    @Test("Excursions suspend outer actions, yield between probes, and restore the outer cache", arguments: [false, true], [false, true])
    func yieldsAndSettles(committed: Bool, collectStats: Bool) throws {
        var propertyCalls = 0
        var machine = try makeExcursionMachine(collectStats: collectStats) { values in
            propertyCalls += 1
            return committed ? false : values[0] < 10 || values[1] < 80
        }
        let checkpoint = machine.sequence
        machine.rejectCache = [0xFEED]
        machine.graphIsStripped = true
        machine.convergence.stallBudget = 0
        machine.phase = .postCycle(remaining: [.excursion, .releaseDeferral])

        let started = try nextExcursionTransition(&machine)
        guard case .excursionAdvanced(step: .started) = started else {
            Issue.record("Excursion preparation must yield before probing")
            return
        }
        #expect(propertyCalls == 0)
        #expect(machine.rejectCache == [0xFEED])
        #expect(machine.deferralReleasedThisCycle == false)
        #expect(machine.activeSession == nil)
        var timings = ReductionStats.StepTimings()
        timings.record(started, elapsed: 11)
        var steps = 1
        var encodedCount = 0
        var decodedCount = 0
        var reachedCompletion = false
        for _ in 0 ..< 10000 {
            let callsBeforeStep = propertyCalls
            let transition = try nextExcursionTransition(&machine)
            timings.record(transition, elapsed: 11)
            steps += 1
            #expect(propertyCalls - callsBeforeStep <= 1)
            #expect(machine.deferralReleasedThisCycle == false)
            #expect(machine.activeSession == nil, "Exploitation must retain its session in the nested loop")
            switch transition {
                case .excursionAdvanced(step: .encoded):
                    encodedCount += 1
                    #expect(propertyCalls == callsBeforeStep)
                case .excursionAdvanced(step: .decoded):
                    decodedCount += 1
                case .excursionAdvanced(step: .exploitationStarted):
                    #expect(propertyCalls == callsBeforeStep)
                    #expect(machine.rejectCache.isEmpty)
                case let .excursionCompleted(improved):
                    #expect(improved == committed)
                    reachedCompletion = true
                case .excursionAdvanced(step: .perturbed):
                    #expect(propertyCalls == callsBeforeStep + 1)
                case .excursionAdvanced:
                    #expect(propertyCalls == callsBeforeStep)
                default:
                    Issue.record("The outer cycle must remain suspended during an excursion")
            }
            if reachedCompletion {
                break
            }
        }
        #expect(reachedCompletion)
        #expect(encodedCount > 0)
        #expect(decodedCount > 0)
        #expect(machine.excursionFrame == nil)
        #expect(machine.rejectCache == [0xFEED])
        #expect(machine.sequence.shortLexPrecedes(checkpoint) == committed)
        #expect(machine.output as? [UInt64] == (committed ? [0, 0] : [10, 80]))
        #expect(ChoiceSequence(machine.tree) == machine.sequence)
        #expect(machine.anyAccepted == committed)
        #expect(machine.anyAcceptanceEverOccurred, "Rollback retains the existing provisional-acceptance history")
        #expect(machine.graphIsStripped)
        #expect(machine.convergence.stallBudget == (committed ? machine.convergence.maxStalls : 0))
        #expect(machine.stats.relaxRoundLog.count == 1)
        #expect(machine.stats.relaxRoundLog.first?.committed == committed)
        #expect(machine.stats.relaxRoundLog.first?.perturbationDecoded == true)
        #expect((machine.stats.reductionProbes > 0) == collectStats)
        #expect(timings.relaxRound == UInt64(steps * 11))
        #expect(timings.dispatch == 0)
        #expect(timings.passApply == 0)
        #expect(timings.encode == 0)
        #expect(timings.decode == 0)
        #expect(timings.rebuild == 0)
        #expect(timings.dispatchCount == 0)
        #expect(timings.passApplyCount == 0)
        #expect(timings.encodeCount == 0)
        #expect(timings.decodeCount == 0)
        #expect(timings.rebuildCount == 0)
        guard case .deferralReleased = machine.next() else {
            Issue.record("Settlement must resume the remaining post-cycle actions")
            return
        }
    }

    @Test("Rollback restores checkpoint convergence after provisional value acceptances")
    func restoresConvergence() throws {
        var machine = try makeExcursionMachine { values in values[0] < 10 || values[1] < 80 }
        for nodeID in machine.graph.leafNodes {
            guard case let .chooseBits(metadata) = machine.graph.nodes[nodeID].kind else {
                continue
            }
            machine.graph.convergenceStore[nodeID] = ConvergedOrigin(
                bound: metadata.value.bitPattern64,
                signal: .monotoneConvergence,
                configuration: .binarySearchSemanticSimplest,
                cycle: 0
            )
        }
        let convergence = machine.graph.convergenceStore
        let checkpoint = machine.sequence
        machine.hadUnresolvedReplacement = true
        machine.rejectCache = [0xFEED]
        machine.phase = .postCycle(remaining: [.excursion])
        let improved = try completeExcursion(&machine)
        #expect(improved == false)
        #expect(machine.sequence == checkpoint)
        #expect(Set(machine.graph.convergenceStore.keys) == Set(convergence.keys))
        for (nodeID, origin) in convergence {
            let restored = try #require(machine.graph.convergenceStore[nodeID])
            #expect(restored.bound == origin.bound)
            #expect(restored.priorBound == origin.priorBound)
            #expect(restored.rebuildGeneration == origin.rebuildGeneration)
            #expect(restored.signal == origin.signal)
            #expect(restored.configuration == origin.configuration)
            #expect(restored.cycle == origin.cycle)
        }
        #expect(machine.hadUnresolvedReplacement)
        #expect(machine.rejectCache == [0xFEED])
        #expect(machine.anyAccepted == false)
        #expect(machine.stats.relaxRoundLog.count == 1)
    }

    @Test("A rejected perturbation spends its budget without starting exploitation or changing the outer cache")
    func rejectionStopsAtBudget() throws {
        var propertyCalls = 0
        var machine = try makeExcursionMachine { _ in
            propertyCalls += 1
            return true
        }
        let checkpoint = machine.sequence
        let initialRebuilds = machine.stats.graphStats.fullGraphRebuilds
        machine.rejectCache = [0xFEED]
        machine.phase = .postCycle(remaining: [.excursion, .releaseDeferral])
        let improved = try completeExcursion(&machine)
        #expect(improved == false)
        #expect(propertyCalls == 1)
        #expect(machine.sequence == checkpoint)
        #expect(machine.rejectCache == [0xFEED])
        #expect(machine.stats.reductionProbes == 1)
        #expect(machine.stats.reductionProbesWherePropertyPassed == 1)
        #expect(machine.stats.reductionProbesAccepted == 0)
        #expect(machine.stats.graphStats.fullGraphRebuilds == initialRebuilds)
        #expect(machine.passCounter == 0)
        #expect(machine.stats.relaxRoundLog.count == 1)
        #expect(machine.stats.relaxRoundLog.first?.materializationsUsed == 1)
        #expect(machine.stats.relaxRoundLog.first?.perturbationDecoded == false)
        #expect(machine.stats.relaxRoundLog.first?.committed == false)
        #expect(machine.excursionFrame == nil)
    }

    @Test("Expiry after exploitation ends settles without repeating reports or probes", arguments: [false, true])
    func deadlineAtSettlement(committed: Bool) throws {
        let clock = ExcursionTestClock()
        var propertyCalls = 0
        var machine = try makeExcursionMachine(clock: clock) { values in
            propertyCalls += 1
            return committed ? false : values[0] < 10 || values[1] < 80
        }
        let checkpoint = machine.sequence
        machine.rejectCache = [0xFEED]
        machine.phase = .postCycle(remaining: [.excursion, .releaseDeferral])
        var reachedSettlement = false
        for _ in 0 ..< 10000 {
            _ = machine.next()
            if case .settle = machine.excursionFrame?.step {
                reachedSettlement = true
                break
            }
        }
        #expect(reachedSettlement)
        let callsBeforeExpiry = propertyCalls
        let passesBeforeExpiry = machine.passCounter
        let rebuildsBeforeExpiry = machine.stats.graphStats.fullGraphRebuilds
        clock.expire()
        _ = machine.next()
        #expect(propertyCalls == callsBeforeExpiry)
        #expect(machine.passCounter == passesBeforeExpiry)
        #expect(machine.stats.graphStats.fullGraphRebuilds == rebuildsBeforeExpiry + (committed ? 0 : 1))
        #expect(machine.sequence.shortLexPrecedes(checkpoint) == committed)
        #expect(machine.output as? [UInt64] == (committed ? [0, 0] : [10, 80]))
        #expect(ChoiceSequence(machine.tree) == machine.sequence)
        #expect(machine.rejectCache == [0xFEED])
        #expect(machine.stats.relaxRoundLog.count == 1)
        #expect(machine.stats.relaxRoundLog.first?.committed == committed)
        #expect(machine.excursionFrame == nil)
        #expect(machine.deferralReleasedThisCycle == false)
        #expect(machine.stats.reductionWasCapped)
        #expect(machine.next() == nil)
        #expect(machine.stats.relaxRoundLog.count == 1)
    }

    @Test("Expiry before a perturbation, before exploitation, or before an exploitation decode restores the checkpoint", arguments: [ExcursionBoundary.prepared, .perturbed, .exploitationPrepared, .encoded])
    func deadlineRestoresCheckpoint(boundary: ExcursionBoundary) throws {
        let clock = ExcursionTestClock()
        var propertyCalls = 0
        var machine = try makeExcursionMachine(clock: clock) { _ in
            propertyCalls += 1
            return false
        }
        let checkpoint = machine.sequence
        let initialRebuilds = machine.stats.graphStats.fullGraphRebuilds
        let initialMaterializations = machine.stats.totalMaterializations
        machine.rejectCache = [0xFEED]
        machine.phase = .postCycle(remaining: [.excursion, .releaseDeferral])
        try advanceExcursion(&machine, to: boundary)
        clock.expire()
        _ = machine.next()
        #expect(machine.excursionFrame == nil)
        #expect(machine.sequence == checkpoint)
        #expect(machine.output as? [UInt64] == [10, 80])
        #expect(ChoiceSequence(machine.tree) == checkpoint)
        #expect(machine.rejectCache == [0xFEED])
        #expect(machine.deferralReleasedThisCycle == false)
        #expect(machine.anyAccepted == false)
        #expect(machine.stats.reductionWasCapped)
        #expect(machine.stats.relaxRoundLog.count == 1)
        #expect(machine.stats.relaxRoundLog.first?.committed == false)
        #expect(machine.activeSession == nil)
        #expect(machine.pendingReport == nil)
        #expect(machine.sources.isEmpty)
        #expect(machine.next() == nil)
        switch boundary {
            case .prepared:
                #expect(propertyCalls == 0)
                #expect(machine.passCounter == 0)
                #expect(machine.stats.reductionProbes == 0)
                #expect(machine.stats.totalMaterializations == initialMaterializations)
                #expect(machine.stats.graphStats.fullGraphRebuilds == initialRebuilds)
            case .perturbed:
                #expect(propertyCalls == 1)
                #expect(machine.passCounter == 0)
                #expect(machine.stats.reductionProbes == 1)
                #expect(machine.stats.totalMaterializations == initialMaterializations + 2)
                #expect(machine.stats.graphStats.fullGraphRebuilds == initialRebuilds)
            case .exploitationPrepared:
                #expect(propertyCalls == 1)
                #expect(machine.passCounter == 0)
                #expect(machine.stats.reductionProbes == 1)
                #expect(machine.stats.totalMaterializations == initialMaterializations + 2)
                #expect(machine.stats.graphStats.fullGraphRebuilds == initialRebuilds + 2)
            case .encoded:
                #expect(propertyCalls == 1)
                #expect(machine.passCounter == 2)
                #expect(machine.stats.reductionProbes == 2)
                #expect(machine.stats.totalMaterializations == initialMaterializations + 2)
                #expect(machine.stats.graphStats.fullGraphRebuilds == initialRebuilds + 2)
        }
    }

    @Test("An exploitation property expiring in flight applies its report and settles once", arguments: [false, true])
    func deadlineDuringExploitation(accepted: Bool) throws {
        let clock = ExcursionTestClock()
        var propertyCalls = 0
        var machine = try makeExcursionMachine(clock: clock) { _ in
            propertyCalls += 1
            if propertyCalls == 2 {
                clock.expire()
                return accepted == false
            }
            return false
        }
        let checkpoint = machine.sequence
        machine.rejectCache = [0xFEED]
        machine.phase = .postCycle(remaining: [.excursion, .releaseDeferral])
        try finishMachine(&machine)
        #expect(propertyCalls == 2)
        #expect(machine.passCounter == 2)
        #expect(machine.sequence.shortLexPrecedes(checkpoint) == accepted)
        #expect(machine.output as? [UInt64] == (accepted ? [0, 0] : [10, 80]))
        #expect(ChoiceSequence(machine.tree) == machine.sequence)
        #expect(machine.rejectCache == [0xFEED])
        #expect(machine.anyAccepted == accepted)
        #expect(machine.stats.reductionProbes == 2)
        #expect(machine.stats.reductionProbesAccepted == (accepted ? 2 : 1))
        #expect(machine.stats.encoderCounts[.valueSearch]?.emitted == 1)
        #expect(machine.stats.encoderCounts[.valueSearch]?.accepted == (accepted ? 1 : 0))
        #expect(machine.stats.relaxRoundLog.count == 1)
        #expect(machine.stats.relaxRoundLog.first?.committed == accepted)
        #expect(machine.stats.reductionWasCapped)
        #expect(machine.deferralReleasedThisCycle == false)
        #expect(machine.excursionFrame == nil)
        #expect(machine.next() == nil)
        #expect(machine.passCounter == 2)
    }

    @Test("An exploitation reshape accepted before expiry rebuilds and reports once", arguments: [false, true])
    func deadlineWithPendingRebuild(reportAlreadyApplied: Bool) throws {
        let clock = ExcursionTestClock()
        var propertyCalls = 0
        var machine = try makeExcursionMachine(clock: clock, allowDeletion: true) { _ in
            propertyCalls += 1
            return false
        }
        let initialRebuilds = machine.stats.graphStats.fullGraphRebuilds
        machine.rejectCache = [0xFEED]
        machine.phase = .postCycle(remaining: [.excursion, .releaseDeferral])
        var reachedDeletion = false
        for _ in 0 ..< 1000 {
            if case .excursionAdvanced(step: .decoded(encoder: .deletion, accepted: true)) = machine.next() {
                reachedDeletion = true
                break
            }
        }
        #expect(reachedDeletion)
        #expect(propertyCalls == 2)
        #expect(machine.passCounter == 0)
        if reportAlreadyApplied {
            guard case .excursionAdvanced(step: .passCompleted(encoder: .deletion, accepted: true)) = machine.next() else {
                Issue.record("The reshape pass must apply its report before rebuilding")
                return
            }
            #expect(machine.passCounter == 1)
        }
        clock.expire()
        _ = machine.next()
        #expect(machine.output as? [UInt64] == [])
        #expect(ChoiceSequence(machine.tree) == machine.sequence)
        #expect(machine.graph.nodes.count == ChoiceGraph.build(from: machine.tree).nodes.count)
        #expect(machine.stats.graphStats.fullGraphRebuilds == initialRebuilds + 2)
        #expect(machine.passCounter == 1)
        #expect(propertyCalls == 2)
        #expect(machine.rejectCache == [0xFEED])
        #expect(machine.stats.encoderCounts[.deletion]?.accepted == 1)
        #expect(machine.stats.reductionProbesAccepted == 2)
        #expect(machine.stats.relaxRoundLog.count == 1)
        #expect(machine.stats.relaxRoundLog.first?.committed == true)
        #expect(machine.anyAccepted)
        #expect(machine.stats.reductionWasCapped)
        #expect(machine.excursionFrame == nil)
        #expect(machine.deferralReleasedThisCycle == false)
        #expect(machine.next() == nil)
        #expect(machine.passCounter == 1)
    }

    @Test("A directly improving excursion perturbation is retained on expiry without preparing exploitation")
    func deadlineKeepsImprovingPerturbation() throws {
        let clock = ExcursionTestClock()
        let generator = excursionArms
        let initial = UInt64(250)
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        var propertyCalls = 0
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: initial,
            config: .init(maxStalls: 2, wallClockDeadlineNanoseconds: 100, enabledEncoders: [.branchPivot]),
            collectStats: true,
            currentNanoseconds: clock.read,
            property: { _ in
                propertyCalls += 1
                clock.expire()
                return false
            }
        )
        machine.collectDiagnostics = true
        machine.rejectCache = [0xFEED]
        let checkpoint = machine.sequence
        let initialRebuilds = machine.stats.graphStats.fullGraphRebuilds
        machine.phase = .postCycle(remaining: [.excursion, .releaseDeferral])
        try finishMachine(&machine)
        #expect(propertyCalls == 1)
        #expect(machine.sequence.shortLexPrecedes(checkpoint))
        #expect(machine.output as? UInt64 == 0)
        #expect(ChoiceSequence(machine.tree) == machine.sequence)
        #expect(machine.stats.graphStats.fullGraphRebuilds == initialRebuilds + 1)
        #expect(machine.rejectCache == [0xFEED])
        #expect(machine.passCounter == 0)
        #expect(machine.stats.reductionProbes == 1)
        #expect(machine.stats.reductionProbesAccepted == 1)
        #expect(machine.stats.relaxRoundLog.count == 1)
        #expect(machine.stats.relaxRoundLog.first?.committed == true)
        #expect(machine.anyAccepted)
        #expect(machine.anyAcceptanceEverOccurred)
        #expect(machine.stats.reductionWasCapped)
        #expect(machine.deferralReleasedThisCycle == false)
        #expect(machine.excursionFrame == nil)
    }
}

// MARK: - Test Helpers

/// Names externally interruptible boundaries without requiring a property callback to expire the clock.
enum ExcursionBoundary {
    case prepared
    case perturbed
    case exploitationPrepared
    case encoded
}

private final class ExcursionTestClock {
    private var nanoseconds: UInt64 = 0

    func read() -> UInt64 {
        nanoseconds
    }

    func expire() {
        nanoseconds = 100
    }
}

private let excursionArms = Gen.pick(choices: [
    (1, Gen.choose(in: UInt64(0) ... 100)),
    (1, Gen.choose(in: UInt64(200) ... 300)),
])

/// Reflects a donor substitution that worsens the checkpoint, so only the nested exploitation loop can make the excursion commit.
private func makeExcursionMachine(
    collectStats: Bool = true,
    clock: ExcursionTestClock? = nil,
    allowDeletion: Bool = false,
    property: @escaping ([UInt64]) -> Bool
) throws -> ReductionMachine {
    let generator = Gen.arrayOf(excursionArms, within: allowDeletion ? 0 ... 3 : 2 ... 2)
    let initial = [UInt64(10), 80]
    let tree = try #require(try Interpreters.reflect(generator, with: initial))
    var tuning = SchedulerTuning()
    tuning.relaxMaterializationBudget = 1
    let enabled: Set<EncoderName> = allowDeletion ? [.substitution, .deletion] : [.substitution, .valueSearch]
    var machine = ReductionMachine(
        gen: generator,
        initialTree: tree,
        initialOutput: initial,
        config: .init(maxStalls: 2, wallClockDeadlineNanoseconds: clock == nil ? 0 : 100, enabledEncoders: enabled, tuning: tuning),
        collectStats: collectStats,
        currentNanoseconds: { clock?.read() ?? 0 },
        property: property
    )
    machine.collectDiagnostics = true
    return machine
}

/// Stops at the final commit decision before the resumed outer cycle can start another pass.
private func completeExcursion(_ machine: inout ReductionMachine) throws -> Bool {
    for _ in 0 ..< 10000 {
        guard let transition = machine.next() else {
            break
        }
        if case let .excursionCompleted(improved) = transition {
            return improved
        }
    }
    Issue.record("The excursion fixture did not settle")
    return false
}

private func advanceExcursion(_ machine: inout ReductionMachine, to boundary: ExcursionBoundary) throws {
    for _ in 0 ..< 1000 {
        let transition = try nextExcursionTransition(&machine)
        switch (boundary, transition) {
            case (.prepared, .excursionAdvanced(step: .started)),
                 (.perturbed, .excursionAdvanced(step: .perturbed(accepted: true))),
                 (.exploitationPrepared, .excursionAdvanced(step: .exploitationStarted)),
                 (.encoded, .excursionAdvanced(step: .encoded(_, cacheHit: false))):
                return
            default:
                break
        }
    }
    Issue.record("The excursion fixture did not reach its requested boundary")
}

private func finishMachine(_ machine: inout ReductionMachine) throws {
    for _ in 0 ..< 10000 {
        guard machine.next() != nil else {
            return
        }
    }
    Issue.record("The excursion fixture did not terminate")
}

private func nextExcursionTransition(_ machine: inout ReductionMachine) throws -> ReductionMachine.Transition {
    let transition = machine.next()
    return try #require(transition)
}
