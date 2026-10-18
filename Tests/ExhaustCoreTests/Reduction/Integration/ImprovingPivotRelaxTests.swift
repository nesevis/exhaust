import Testing
@testable import ExhaustCore

@Suite("Relax round improving pivots")
struct ImprovingPivotRelaxTests {
    @Test("Every leaf fill flattens to the same length", arguments: PivotLeafFill.allCases)
    func fillsKeepLength(fill: PivotLeafFill) throws {
        let (_, tree) = try laterArmCounterexample(threshold: 1, seed: 3, materializePicks: true)
        let minimal = ChoiceSequence.flatten(PivotLeafFill.reductionTarget.seed(for: tree))
        #expect(ChoiceSequence.flatten(fill.seed(for: tree)).count == minimal.count)
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
