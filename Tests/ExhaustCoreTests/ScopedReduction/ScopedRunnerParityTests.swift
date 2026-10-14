import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Scoped runner parity")
struct ScopedRunnerParityTests {
    @Test(
        "The scoped runner reduces every fixture to the current reducer's counterexample with the same accounting",
        arguments: RunnerCase.all
    )
    func parity(runnerCase: RunnerCase) throws {
        let fixture = try runnerCase.makeFixture()
        let legacy = Interpreters.choiceGraphReduceCollectingStats(
            gen: fixture.generator,
            tree: fixture.tree,
            output: fixture.output,
            config: Interpreters.ReducerConfiguration(maxStalls: RunnerCase.maxStalls),
            property: fixture.property
        )
        let scoped = ScopedReductionRunner.reduce(
            generator: fixture.generator,
            tree: fixture.tree,
            output: fixture.output,
            configuration: ScopedReductionRunner.Configuration(maxStalls: RunnerCase.maxStalls),
            collectStats: true,
            property: fixture.property
        )

        #expect(RunnerCase.sequence(of: scoped.outcome) == RunnerCase.sequence(of: legacy.outcome))
        #expect(RunnerCase.isReduced(scoped.outcome) == RunnerCase.isReduced(legacy.outcome))
        #expect(scoped.stats.encoderCounts == legacy.stats.encoderCounts)
        #expect(scoped.stats.numericSearchCountsByArity == legacy.stats.numericSearchCountsByArity)
        #expect(scoped.stats.materializationsBySite == legacy.stats.materializationsBySite)
        #expect(scoped.stats.cycles == legacy.stats.cycles)
        #expect(scoped.stats.boundValueBuildOutcomes == legacy.stats.boundValueBuildOutcomes)
        #expect(scoped.stats.relaxImprovingProbes == legacy.stats.relaxImprovingProbes)
        #expect(scoped.stats.relaxImprovingAcceptances == legacy.stats.relaxImprovingAcceptances)
        #expect(scoped.stats.reductionProbes == legacy.stats.reductionProbes)
        #expect(scoped.stats.stalledLeafCount == legacy.stats.stalledLeafCount)
        #expect(scoped.stats.anyAcceptanceEverOccurred == legacy.stats.anyAcceptanceEverOccurred)
        #expect(scoped.stats.reductionWasCapped == legacy.stats.reductionWasCapped)
        #expect(scoped.stats.graphStats.fullGraphRebuilds == legacy.stats.graphStats.fullGraphRebuilds)
    }
}

// MARK: - Cases

/// A starting counterexample from one of the encoder parity suites, reduced end to end.
struct RunnerCase: CustomStringConvertible, Sendable {
    struct Fixture {
        let generator: AnyGenerator
        let tree: ChoiceTree
        let output: Any
        let property: (Any) -> Bool
    }

    static let maxStalls = 2

    let label: String
    let makeFixture: @Sendable () throws -> Fixture

    var description: String {
        label
    }

    static let all: [RunnerCase] = boundValueCases + exchangeCases + pivotCases + depthCases + laneCases
        + valueCases + redistributionCases + lockstepCases + relationCases + stagedJointCases + structuralCases

    private static let boundValueCases = BoundValueCase.all.map { boundValueCase in
        RunnerCase(label: "bound value: \(boundValueCase)") {
            let fixture = try BoundValueFixture(boundValueCase)
            return Fixture(generator: fixture.generator, tree: fixture.tree, output: fixture.output, property: fixture.property)
        }
    }

    private static let exchangeCases = ExchangeCase.all.map { exchangeCase in
        RunnerCase(label: "bound exchange: \(exchangeCase)") {
            let fixture = try ScopedExchangeFixture(exchangeCase)
            return Fixture(generator: fixture.generator, tree: fixture.tree, output: fixture.output, property: fixture.property)
        }
    }

    private static let pivotCases = PivotProperty.allCases.map { pivotProperty in
        RunnerCase(label: "bind pivot: \(pivotProperty)") {
            let fixture = try PivotParityFixture(property: pivotProperty)
            return Fixture(generator: fixture.generator, tree: fixture.tree, output: fixture.output, property: fixture.property)
        }
    }

    private static let depthCases = (0 ... 5).map { failingCount in
        RunnerCase(label: "depth collapse: fails at \(failingCount)") {
            let fixture = try DepthCollapseFixture(failingCount: failingCount)
            return Fixture(generator: fixture.generator, tree: fixture.tree, output: fixture.output, property: fixture.property)
        }
    }

    private static let laneCases = LaneCase.all.map { laneCase in
        RunnerCase(label: "lane collapse: \(laneCase)") {
            let fixture = try LaneCollapseFixture(laneCase)
            return Fixture(generator: fixture.generator, tree: fixture.tree, output: fixture.output, property: fixture.property)
        }
    }

    private static let valueCases = ValueCase.all.filter { $0.deadlineAfterChecks == nil }.map { valueCase in
        RunnerCase(label: "value search: \(valueCase)") {
            let fixture = try ValueSearchFixture(valueCase)
            return Fixture(generator: fixture.generator, tree: fixture.tree, output: fixture.output, property: fixture.property)
        }
    }

    private static let redistributionCases = RedistributionCase.all.map { redistributionCase in
        RunnerCase(label: "redistribution: \(redistributionCase)") {
            let fixture = try RedistributionFixture(redistributionCase)
            return Fixture(generator: fixture.generator, tree: fixture.tree, output: fixture.output, property: fixture.property)
        }
    }

    private static let lockstepCases = LockstepCase.all.map { lockstepCase in
        RunnerCase(label: "lockstep: \(lockstepCase)") {
            let fixture = try LockstepFixture(lockstepCase)
            return Fixture(generator: fixture.generator, tree: fixture.tree, output: fixture.output, property: fixture.property)
        }
    }

    private static let relationCases = RelationCase.all.map { relationCase in
        RunnerCase(label: "relation: \(relationCase)") {
            let fixture = try RelationFixture(relationCase)
            return Fixture(generator: fixture.generator, tree: fixture.tree, output: fixture.output, property: fixture.property)
        }
    }

    private static let stagedJointCases = StagedJointCase.all.map { stagedJointCase in
        RunnerCase(label: "staged joint: \(stagedJointCase)") {
            let fixture = try StagedJointFixture(stagedJointCase)
            return Fixture(generator: fixture.generator, tree: fixture.tree, output: stagedJointCase.values, property: fixture.property)
        }
    }

    private static let structuralCases = StructuralCase.all.map { structuralCase in
        RunnerCase(label: "structural: \(structuralCase)") {
            let fixture = try StructuralFixture(structuralCase)
            return Fixture(generator: fixture.generator, tree: fixture.tree, output: fixture.output, property: fixture.property)
        }
    }

    // MARK: - Helpers

    static func sequence(of outcome: ReductionOutcome<Any>) -> [ChoiceSequenceValue]? {
        switch outcome {
            case let .reduced(sequence, _, _), let .unreduced(sequence, _, _):
                Array(sequence)
            case .failure:
                nil
        }
    }

    static func isReduced(_ outcome: ReductionOutcome<Any>) -> Bool {
        guard case .reduced = outcome else {
            return false
        }
        return true
    }
}
