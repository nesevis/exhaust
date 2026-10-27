import Testing
@testable import ExhaustCore

@Suite("Post-cycle acceptance invalidation")
struct PostCycleInvalidationTests {
    @Test("Confirmation invalidates only the witnessed floor and preserves bind budget decay", arguments: [false, true])
    func confirmationInvalidation(accepts: Bool) throws {
        let leaf = Gen.choose(in: UInt64(0) ... 100)
        let generator = Gen.zip(leaf, leaf)
        let start = (UInt64(50), UInt64(80))
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: start,
            configuration: .init(maxStalls: 2),
            collectStats: false,
            property: { value in value != start && (accepts == false || value != (49, 80)) }
        )
        runner.graph.markLeavesConverged()
        let evidence = CachedPostCycleEvidence(runner: &runner)

        #expect(runner.runPostCycleActions([.confirmConvergence]) == .completed)

        let output = try #require(runner.incumbent.output as? (UInt64, UInt64))
        #expect(output == (accepts ? (49, 80) : start))
        #expect(floors(in: runner) == (accepts ? [nil, 80] : [50, 80]))
        #expect(runner.anyAccepted == accepts)
        evidence.check(in: runner, accepted: accepts, resetsBindBudget: false)
    }

    @Test("Relation clears coupled floors without resetting bind budgets", arguments: [false, true])
    func relationInvalidation(accepts: Bool) throws {
        let leaf = Gen.choose(in: UInt64(0) ... 100)
        let generator = Gen.zip(leaf, leaf, leaf)
        let start = (UInt64(6), UInt64(9), UInt64(7))
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: start,
            configuration: .init(maxStalls: 2),
            collectStats: false,
            property: { value in
                if accepts == false {
                    return value != start
                }
                return value.0 == 0 || value.0 * 3 != value.1 * 2 || value.2 < value.0 + 1
            }
        )
        runner.graph.markLeavesConverged()
        let evidence = CachedPostCycleEvidence(runner: &runner)

        #expect(runner.runPostCycleActions([.relationPass]) == .completed)

        let output = try #require(runner.incumbent.output as? (UInt64, UInt64, UInt64))
        #expect(output == (accepts ? (2, 3, 7) : start))
        // The unchanged third leaf's old floor depended on the pair's scale.
        #expect(floors(in: runner) == (accepts ? [nil, nil, nil] : [6, 9, 7]))
        evidence.check(in: runner, accepted: accepts, resetsBindBudget: false)
    }

    @Test("Staged joint acceptance clears coupled floors and restores bind budgets", arguments: [false, true])
    func stagedJointInvalidation(accepts: Bool) throws {
        let generator = Gen.arrayOf(Gen.choose(in: -100 ... 100), exactly: 3)
        let start = [-3, 5, 17]
        let improved = [3, -5, 17]
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        var tuning = ReductionTuning()
        tuning.stagedJointProbeBudget = 1
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: start,
            configuration: .init(maxStalls: 2, enabledEncoders: [.stagedJointSearch], tuning: tuning),
            collectStats: false,
            property: { $0 != start && (accepts == false || $0 != improved) }
        )
        runner.graph.markLeavesConverged()
        let originalFloors = floors(in: runner)
        let evidence = CachedPostCycleEvidence(runner: &runner)

        #expect(runner.runPostCycleActions([.stagedJointPass]) == .completed)

        #expect(runner.incumbent.output as? [Int] == (accepts ? improved : start))
        #expect(floors(in: runner) == (accepts ? Array(repeating: nil, count: originalFloors.count) : originalFloors))
        evidence.check(in: runner, accepted: accepts, resetsBindBudget: accepts)
    }

    @Test("An improving pivot retains the unchanged sibling's floor and bind budget decay", arguments: [false, true])
    func pivotInvalidation(accepts: Bool) throws {
        let arms = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 100)),
            (1, Gen.choose(in: UInt64(200) ... 300)),
        ])
        let generator = Gen.zip(arms, Gen.choose(in: UInt64(0) ... 100))
        let start = (UInt64(250), UInt64(80))
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: start,
            configuration: .init(maxStalls: 2, enabledEncoders: [.branchPivot]),
            collectStats: false,
            property: { $0 != start && accepts == false }
        )
        runner.graph.markLeavesConverged()
        let evidence = CachedPostCycleEvidence(runner: &runner)

        #expect(runner.runPostCycleActions([.improvingPivots]) == .completed)

        let output = try #require(runner.incumbent.output as? (UInt64, UInt64))
        #expect(accepts ? output.0 <= 100 : output.0 == 250)
        #expect(output.1 == 80)
        #expect(floors(in: runner) == (accepts ? [nil, 80] : [250, 80]))
        evidence.check(in: runner, accepted: accepts, resetsBindBudget: false)
    }

    @Test("A committed relax round retains the floor learned during exploitation")
    func relaxRetainsExploitationFloor() throws {
        let arms = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 100)),
            (1, Gen.choose(in: UInt64(200) ... 300)),
        ])
        let generator = Gen.arrayOf(arms, within: 0 ... 3)
        let start: [UInt64] = [10, 80]
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        var tuning = ReductionTuning()
        tuning.relaxMaterializationBudget = 1
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: start,
            configuration: .init(
                maxStalls: 2,
                enabledEncoders: [.substitution, .deletion, .valueSearch],
                tuning: tuning
            ),
            collectStats: false,
            property: { $0.isEmpty || $0[0] < 5 }
        )
        let evidence = CachedPostCycleEvidence(runner: &runner)

        #expect(runner.runPostCycleActions([.relaxRound]) == .completed)

        #expect(runner.incumbent.output as? [UInt64] == [5])
        let valueLeaf = try #require(runner.graph.leafNodes.last)
        #expect(runner.graph.convergenceStore[valueLeaf]?.bound == 5)
        evidence.check(in: runner, accepted: true, resetsBindBudget: false)
    }

    private func floors(in runner: ReductionSession) -> [UInt64?] {
        runner.graph.leafNodes.filter { runner.graph.nodes[$0].positionRange != nil }
            .map { runner.graph.convergenceStore[$0]?.bound }
    }
}

// MARK: - Cache and bind history fixture

/// Seeds each cache evidence class, including guided evidence that must stay stored but miss after the incumbent changes.
private struct CachedPostCycleEvidence {
    let incumbentHash: UInt64
    private let fingerprint: UInt64 = 42
    private let decisions = [false, false, true, true, true].map { ProbeDecision(isGuided: $0) }

    /// Uses distinct probe hashes so each evidence class can be checked independently after acceptance.
    init(runner: inout ReductionSession) {
        incumbentHash = runner.incumbentHash
        runner.stallBudget = 0
        runner.gate = BoundValueGate(baseBudget: 64)
        runner.gate.markDispatched(fingerprint)
        runner.gate.recordOutcome(fingerprint: fingerprint, accepted: false)
        runner.gate.recordOutcome(fingerprint: fingerprint, accepted: false)
        for (index, decision) in decisions.enumerated() {
            let lookup = runner.rejectCache.lookup(
                probeHash: UInt64(index + 1000),
                decision: decision,
                incumbentHash: incumbentHash
            )
            let sources: MaterializationSources = index == 4 ? .prefix : .unknown
            let outcome: SequenceDecodingOutcome = switch index {
                case 0, 2:
                    .materializationRejected(materializationAttempts: 1)
                default:
                    .propertyPassed(materializationAttempts: 1, sources: sources)
            }
            runner.rejectCache.record(lookup, outcome: outcome)
        }
    }

    /// Checks both contexts: incumbent-dependent evidence must remain stored even when it cannot answer for the new incumbent.
    func check(in runner: ReductionSession, accepted: Bool, resetsBindBudget: Bool) {
        #expect((runner.incumbentHash != incumbentHash) == accepted)
        #expect(runner.anyAccepted == accepted)
        #expect(runner.anyAcceptanceEverOccurred == accepted)
        #expect(runner.stallBudget == (accepted ? 2 : 0))
        #expect(runner.gate.decayedBudget(fingerprint: fingerprint) == (resetsBindBudget ? 64 : 16))
        #expect(runner.gate.isFruitless(fingerprint) == (accepted == false))
        #expect(runner.gate.isFirstDispatch(fingerprint: fingerprint) == false)
        #expect(runner.gate.shouldDispatch(fingerprint: fingerprint) == .skip)
        for (index, decision) in decisions.enumerated() {
            let probeHash = UInt64(index + 1000)
            #expect(runner.rejectCache.lookup(probeHash: probeHash, decision: decision, incumbentHash: incumbentHash)
                .isCached)
            let reused = runner.rejectCache.lookup(
                probeHash: probeHash,
                decision: decision,
                incumbentHash: runner.incumbentHash
            )
            #expect(reused.isCached == (accepted == false || index < 2 || index == 4))
        }
    }
}
