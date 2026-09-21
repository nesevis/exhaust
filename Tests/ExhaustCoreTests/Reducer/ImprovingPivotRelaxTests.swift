import Testing
@testable import ExhaustCore

@Suite("Relax round improving pivots")
struct ImprovingPivotRelaxTests {
    @Test("A counterexample in the later arm reduces to the earlier arm's threshold", arguments: [UInt64(1), 150, 200], [UInt64(3), 11, 42])
    func reducesAcrossArms(threshold: UInt64, seed: UInt64) throws {
        var machine = try makeMachine(threshold: threshold, seed: seed, improvingProbeBudget: SchedulerTuning().relaxImprovingProbeBudget)
        while try machine.next() != nil {}
        #expect(machine.output as? UInt64 == threshold)
        #expect(machine.stats.relaxImprovingAcceptances == 1)
    }

    @Test("An improving pivot accepted on the last stall is still minimized", arguments: [UInt64(3), 11, 42])
    func acceptedPivotIsMinimizedOnTheLastStall(seed: UInt64) throws {
        var machine = try makeMachine(threshold: 150, seed: seed, improvingProbeBudget: 2, maxStalls: 1)
        while try machine.next() != nil {}
        #expect(machine.output as? UInt64 == 150)
    }

    @Test("Without an improving probe budget the counterexample stays in the arm it was found in", arguments: [UInt64(3), 11, 42])
    func budgetZeroStaysInArm(seed: UInt64) throws {
        var machine = try makeMachine(threshold: 1, seed: seed, improvingProbeBudget: 0)
        while try machine.next() != nil {}
        #expect(machine.output as? UInt64 == 300)
        #expect(machine.stats.relaxImprovingProbes == 0)
    }

    @Test("A pivot whose minimal content fails is taken by the guarded encoder, not the relax round", arguments: [UInt64(3), 11, 42])
    func minimalContentNeedsNoImprovingProbe(seed: UInt64) throws {
        var machine = try makeMachine(threshold: 0, seed: seed, improvingProbeBudget: SchedulerTuning().relaxImprovingProbeBudget)
        while try machine.next() != nil {}
        #expect(machine.output as? UInt64 == 0)
        #expect(machine.stats.relaxImprovingProbes == 0)
    }

    @Test("Every leaf fill flattens to the same length", arguments: PivotLeafFill.allCases)
    func fillsKeepLength(fill: PivotLeafFill) throws {
        let (_, tree) = try laterArmCounterexample(threshold: 1, seed: 3, materializePicks: true)
        let minimal = ChoiceSequence.flatten(PivotLeafFill.reductionTarget.apply(to: tree))
        #expect(ChoiceSequence.flatten(fill.apply(to: tree)).count == minimal.count)
    }

    @Test("The farthest fill moves a leaf to the bound opposite its reduction target")
    func farthestFillReachesTheOppositeBound() {
        let metadata = ChoiceMetadata(validRange: 0 ... 200)
        let leaf = ChoiceTree.choice(ChoiceValue(UInt64(37), tag: .uint64), metadata)
        guard case let .choice(value, _) = leaf.maximizingLeaves else {
            Issue.record("Expected a choice leaf")
            return
        }
        #expect(value.bitPattern64 == 200)
    }
}

// MARK: - Helpers

private let twoArms: Generator<UInt64> = Gen.pick(choices: [
    (1, Gen.choose(in: UInt64(0) ... 200)),
    (1, Gen.choose(in: UInt64(300) ... 500)),
])

/// A value from the later arm that fails `value < threshold`, with its tree.
private func laterArmCounterexample(
    threshold: UInt64,
    seed: UInt64,
    materializePicks: Bool
) throws -> (UInt64, ChoiceTree) {
    var iterator = ValueAndChoiceTreeInterpreter(twoArms, materializePicks: materializePicks, seed: seed, maxRuns: 500)
    while let (value, tree) = try iterator.next() {
        if value >= 300, value >= threshold {
            return (value, tree)
        }
    }
    throw GeneratorError.choiceTreeConstructionFailed
}

private func makeMachine(
    threshold: UInt64,
    seed: UInt64,
    improvingProbeBudget: Int,
    maxStalls: Int = 4
) throws -> ReductionMachine {
    let (value, tree) = try laterArmCounterexample(threshold: threshold, seed: seed, materializePicks: false)
    var tuning = SchedulerTuning()
    tuning.relaxImprovingProbeBudget = improvingProbeBudget
    return ReductionMachine(
        gen: twoArms,
        initialTree: tree,
        initialOutput: value,
        config: Interpreters.ReducerConfiguration(maxStalls: maxStalls, tuning: tuning),
        collectStats: true,
        property: { $0 < threshold }
    )
}
