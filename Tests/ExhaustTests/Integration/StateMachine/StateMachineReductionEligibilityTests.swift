import ExhaustCore
import ExhaustTestSupport
import Testing
@testable import Exhaust

@Suite("State-machine value reduction eligibility")
struct StateMachineReductionEligibilityTests {
    @Test("The concurrent value pass reopens a floor made stale by reducing another value")
    func concurrentValuePassReopensStaleFloor() throws {
        let generator = Gen.zip(
            Gen.choose(in: UInt64(0) ... 100),
            Gen.choose(in: UInt64(0) ... 100)
        )
        let output = (UInt64(50), UInt64(50))
        let tree = try #require(try Interpreters.reflect(generator, with: output))
        let result: __ExhaustRuntime.ConcurrentTwoPassResult<(UInt64, UInt64), Void> = __ExhaustRuntime.reduceConcurrentTwoPass(
            generator: generator,
            tree: tree,
            output: output,
            deadlineNanoseconds: 0,
            property: { value in
                let firstFloor: UInt64 = value.1 == 20 ? 8 : 10
                return value.0 >= firstFloor && value.1 >= 20 ? .fail(()) : .pass
            }
        )

        #expect(result.value.0 == 8)
        #expect(result.value.1 == 20)
        #expect((result.stats.encoderCounts[.convergenceConfirmation]?.accepted ?? 0) > 0)
    }

    @Test("The concurrent value pass confirms convergence without enabling structural replacements")
    func concurrentValuePassConfirmsConvergence() throws {
        let generator = Gen.choose(in: UInt64(0) ... 100)
        let output = UInt64(50)
        let tree = try #require(try Interpreters.reflect(generator, with: output))
        let result: __ExhaustRuntime.ConcurrentTwoPassResult<UInt64, Void> = __ExhaustRuntime.reduceConcurrentTwoPass(
            generator: generator,
            tree: tree,
            output: output,
            deadlineNanoseconds: 0,
            property: { value in value >= 10 ? .fail(()) : .pass }
        )

        #expect(result.value == 10)
        #expect(result.aborted == false)
        #expect((result.stats.encoderCounts[.convergenceConfirmation]?.emitted ?? 0) > 0)
        #expect(Set(result.stats.encoderCounts.keys).isSubset(of: [.valueSearch, .floatSearch, .convergenceConfirmation]))
        #expect(result.stats.relaxImprovingProbes == 0)
        #expect(result.stats.reductionProbes == result.stats.encoderCounts.values.reduce(0) { $0 + $1.emitted })
        guard case let .success(replayed, _, _) = Materializer.materialize(
            generator,
            context: .init(prefix: result.sequence, mode: .exact)
        ) else {
            Issue.record("The reduced value must replay from its authoritative choice sequence")
            return
        }
        #expect(replayed == result.value)
    }

    @Test("The setup pass confirms convergence while preserving the fixed commands")
    func setupPassConfirmsConvergence() throws {
        let setupGenerator = try #require(ConfirmationSpec.setupGenerator)
        let setup = UInt64(50)
        let setupTree = try #require(try Interpreters.reflect(setupGenerator.gen, with: setup))
        let commands: [(ScheduleMarker, UInt64)] = [(.prefix, 7)]
        let commandGenerator = Gen.just(commands)
        let commandTree = try #require(try Interpreters.reflect(commandGenerator, with: commands))
        let candidate = StateMachineCandidate<ConfirmationSpec>(
            value: SpecCandidateValue(setupStep: setup, taggedCommands: commands),
            tree: .group([setupTree, commandTree]),
            sequenceGen: commandGenerator,
            iteration: 1,
            provenance: .randomSampling(seed: 42)
        )
        var config = ResolvedConcurrentConfig()
        config.suppress.issueReporting = true
        let context = StateMachineRunContext<ConfirmationSpec>(
            config: config,
            sequenceGen: commandGenerator,
            commandGen: ConfirmationSpec.commandGenerator.gen,
            commandLimit: 1,
            identifySkips: { _ in [] },
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column
        )
        var machine = SpecMachine(
            backend: ConfirmationBackend(),
            context: context,
            sources: [AnyStateMachineCandidateSource<ConfirmationSpec> { candidate }]
        )
        for _ in 0 ..< 20 {
            guard let transition = machine.next() else {
                Issue.record("The machine must run setup reduction before terminating")
                return
            }
            if case .setupReduced = transition {
                let stats = try #require(machine.setupReductionStats)
                #expect(machine.reducedSetupStep == 10)
                #expect(machine.reductionInput?.taggedCommands.map(\.1) == [7])
                #expect((stats.encoderCounts[.convergenceConfirmation]?.emitted ?? 0) > 0)
                #expect(Set(stats.encoderCounts.keys).isSubset(of: [.valueSearch, .floatSearch, .deletion, .convergenceConfirmation]))
                #expect(stats.relaxImprovingProbes == 0)
                #expect(stats.reductionProbes == stats.encoderCounts.values.reduce(0) { $0 + $1.emitted })
                return
            }
        }
        Issue.record("The setup fixture must reach setup reduction within 20 transitions")
    }
}

private struct ConfirmationSpec: StateMachineSpecBase {
    typealias Command = UInt64
    typealias SetupStep = UInt64
    typealias SystemUnderTest = Int

    static var commandGenerator: ReflectiveGenerator<UInt64> {
        #gen(.just(UInt64(7)))
    }

    static var setupGenerator: ReflectiveGenerator<UInt64>? {
        #gen(.uint64(in: 0 ... 100))
    }

    var systemUnderTest: Int {
        0
    }

    func failureDescription() -> String? {
        nil
    }

    init() {}
}

/// Keeps failure dependent only on setup so the actual setup pass must minimize it against unchanged commands.
private struct ConfirmationBackend: StateMachineBackend {
    typealias Spec = ConfirmationSpec

    func probe(_ candidate: SpecCandidateValue<Spec>, context _: StateMachineRunContext<Spec>) -> ProbeOutcome {
        (candidate.setupStep ?? 0) >= 10 ? .fail : .pass
    }

    func reduce(
        setupStep _: UInt64?,
        taggedCommands: [(ScheduleMarker, UInt64)],
        tree _: ChoiceTree,
        context _: StateMachineRunContext<Spec>
    ) -> StateMachineReduction<UInt64> {
        StateMachineReduction(finalInput: taggedCommands, stats: nil, timedOut: false)
    }

    func buildResult(
        setupStep: UInt64?,
        reduced: [(ScheduleMarker, UInt64)],
        originalCommands: [UInt64]?,
        provenance: StateMachineCandidateProvenance,
        iteration _: Int,
        context _: StateMachineRunContext<Spec>
    ) -> (result: StateMachineResult<Spec>, issueMessage: String) {
        let result = StateMachineResult<Spec>(
            commands: reduced.map(\.1),
            originalCommands: originalCommands,
            setup: setupStep,
            trace: [],
            systemUnderTest: 0,
            seed: provenance.resultSeed,
            replaySeed: nil,
            discoveryMethod: provenance.discoveryMethod
        )
        return (result, "setup confirmation fixture")
    }
}
