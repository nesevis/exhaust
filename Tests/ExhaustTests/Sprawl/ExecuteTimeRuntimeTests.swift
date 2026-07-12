import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing
@testable import Exhaust

@Suite("#execute(time:) runtime dispatch and adapter")
struct ExecuteTimeRuntimeTests {
    @Test(".threads spec produces a diagnostic and zero attempts")
    func threadsSpecDiagnostic() async throws {
        nonisolated(unsafe) var report: SprawlReport?
        await withKnownIssue {
            report = await __ExhaustRuntime.__runStateMachineTimeDispatch(
                ThreadsCounterSpec.self,
                time: .seconds(60),
                settings: []
            )
        }
        let resolved = try #require(report)
        #expect(resolved.totalAttempts == 0)
        guard case .invalidConfiguration = resolved.termination else {
            Issue.record("Expected invalidConfiguration, got \(resolved.termination)")
            return
        }
    }

    @Test(".tasks spec produces a diagnostic and zero attempts")
    func tasksSpecDiagnostic() async throws {
        nonisolated(unsafe) var report: SprawlReport?
        await withKnownIssue {
            report = await __ExhaustRuntime.__runStateMachineTimeDispatch(
                TasksCounterSpec.self,
                time: .seconds(60),
                settings: []
            )
        }
        let resolved = try #require(report)
        #expect(resolved.totalAttempts == 0)
        guard case .invalidConfiguration = resolved.termination else {
            Issue.record("Expected invalidConfiguration, got \(resolved.termination)")
            return
        }
    }

    @Test("Sequential adapter property maps passing spec to .pass")
    func adapterPropertyPass() {
        let adapter = __ExhaustRuntime.buildSequentialSpecAdapter(AlwaysPassingSpec.self)
        let tagged: [(ScheduleMarker, AlwaysPassingSpec.Command)] = [
            (.prefix, .increment),
        ]
        let verdict = adapter.property(tagged)
        #expect(verdict.isFailure == false)
    }

    @Test("Sequential adapter property maps failing spec to .fail")
    func adapterPropertyFail() {
        let adapter = __ExhaustRuntime.buildSequentialSpecAdapter(FailsAtThreeSpec.self)
        let tagged: [(ScheduleMarker, FailsAtThreeSpec.Command)] = [
            (.prefix, .increment),
            (.prefix, .increment),
            (.prefix, .increment),
        ]
        let verdict = adapter.property(tagged)
        #expect(verdict.isFailure)
    }

    @Test("Adapter preserves the thrown error type as the failure symptom")
    func adapterSymptomPreservesThrownErrorType() {
        let adapter = __ExhaustRuntime.buildSequentialSpecAdapter(ThrowingAtThreeSpec.self)
        let tagged: [(ScheduleMarker, ThrowingAtThreeSpec.Command)] = [
            (.prefix, .increment),
            (.prefix, .increment),
            (.prefix, .increment),
        ]
        guard case let .fail(symptom) = adapter.property(tagged) else {
            Issue.record("Expected a failing verdict")
            return
        }
        #expect(symptom.kind == "PlantedSpecError")
    }

    @Test("Adapter maps an invariant violation to the check-failure symptom")
    func adapterSymptomForInvariantViolation() {
        let adapter = __ExhaustRuntime.buildSequentialSpecAdapter(FailsAtThreeSpec.self)
        let tagged: [(ScheduleMarker, FailsAtThreeSpec.Command)] = [
            (.prefix, .increment),
            (.prefix, .increment),
            (.prefix, .increment),
        ]
        guard case let .fail(symptom) = adapter.property(tagged) else {
            Issue.record("Expected a failing verdict")
            return
        }
        #expect(symptom.kind == "StateMachineCheckFailure")
    }

    @Test("Sequential adapter runs end-to-end with synthetic coverage and finds the fault")
    func adapterEndToEnd() {
        let adapter = __ExhaustRuntime.buildSequentialSpecAdapter(FailsAtThreeSpec.self)
        let source = SyntheticCoverageSource<[(ScheduleMarker, FailsAtThreeSpec.Command)]>(
            edgeCount: 16,
            edges: { tagged in
                [tagged.count % 8]
            }
        )
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: adapter.generator,
            time: .seconds(5),
            settings: [.replay(7)],
            source: source,
            configure: { configuration in
                configuration.skipScreening = true
                configuration.reductionPoolWidth = 1
                configuration.attemptLimit = 500
            },
            hooks: adapter.hooks,
            property: adapter.property
        )
        #expect(report.clusters.isEmpty == false)
        #expect(report.clusters.count == 1)
    }

    @Test("commandLimit setting caps generated sequence length")
    func commandLimitCapsLength() {
        let adapter = __ExhaustRuntime.buildSequentialSpecAdapter(SkippableCounterSpec.self, commandLimit: 5)
        let source = SyntheticCoverageSource<[(ScheduleMarker, SkippableCounterSpec.Command)]>(
            edgeCount: 16,
            edges: { tagged in
                [tagged.count % 8]
            }
        )
        var configuration = SprawlRunnerConfiguration(
            budgetNanoseconds: 60_000_000_000,
            seed: 7,
            skipScreening: true,
            attemptLimit: 200
        )
        configuration.reductionPoolWidth = 1

        let runner = SprawlRunner(
            gen: adapter.generator,
            property: adapter.property,
            source: source,
            configuration: configuration,
            hooks: adapter.hooks
        )
        let result = runner.run()
        #expect(result.corpusEntryCount > 0)

        for index in runner.corpus.mutableTierIndices {
            let entry = runner.corpus.entries[index]
            guard case let .success(value, _, _) = Materializer.materialize(
                adapter.generator, prefix: entry.sequence, mode: .exact, fallbackTree: entry.tree
            ) else {
                continue
            }
            #expect(value.count <= 5, "Corpus entry \(index) has \(value.count) commands, exceeding commandLimit 5")
        }
    }

    @Test("commandLimit below 1 is a configuration error")
    func commandLimitBelowOne() async throws {
        nonisolated(unsafe) var report: SprawlReport?
        await withKnownIssue {
            report = await __ExhaustRuntime.__runStateMachineTimeDispatch(
                SkippableCounterSpec.self,
                time: .seconds(60),
                settings: [.commandLimit(0)]
            )
        }
        let resolved = try #require(report)
        #expect(resolved.totalAttempts == 0)
        guard case .invalidConfiguration = resolved.termination else {
            Issue.record("Expected invalidConfiguration, got \(resolved.termination)")
            return
        }
    }

    @Test("commandLimit on #explore(time:) is a configuration error")
    func commandLimitOnExplorePath() {
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
            time: .seconds(60),
            settings: [.commandLimit(10)],
            source: SyntheticCoverageSource<Int>(edgeCount: 8, edges: { [$0 % 4] }),
            configure: nil,
            property: { _ in .pass }
        )
        guard case .invalidConfiguration = report.termination else {
            Issue.record("Expected invalidConfiguration, got \(report.termination)")
            return
        }
        #expect(report.totalAttempts == 0)
    }

    @Test("Swarm mask reaches the synthesized commandGenerator pick site")
    func swarmMaskReachesCommandGenerator() throws {
        let adapter = __ExhaustRuntime.buildSequentialSpecAdapter(SkippableCounterSpec.self)
        var interpreter = ValueAndChoiceTreeInterpreter(adapter.generator, materializePicks: false, seed: 1, maxRuns: 3)
        let (_, tree) = try #require(try interpreter.next())
        let branches = ChoiceSequence.flatten(tree).compactMap { entry -> ChoiceSequenceValue.Branch? in
            guard case let .branch(branch) = entry else {
                return nil
            }
            return branch
        }
        #expect(branches.isEmpty == false, "the command generator should produce at least one branch entry")
        #expect(branches.allSatisfy { $0.fingerprint != 0 }, "all branch entries must carry a non-zero fingerprint for swarm masking to work")

        // The fingerprint is the source location of the synthesized pick, so it shifts whenever this file is edited above the spec; any single epoch masks a 2-branch site with probability 3/8. Scanning 64 epochs makes the check deterministic in practice (miss probability (5/8)^64) without pinning a fingerprint.
        let maskingEpochExists = (0 ..< 64).contains { epoch in
            let mask = SwarmMask.forEpoch(index: epoch, rootSeed: 42)
            return branches.contains { branch in
                mask.allowedBranches(fingerprint: branch.fingerprint, branchCount: branch.branchCount) != nil
            }
        }
        #expect(maskingEpochExists, "at least one epoch should mask the command generator's pick site")
    }

    @Test("A slow property body overshoots the budget by whole attempts and the run still returns")
    func slowPropertyOvershootsBudget() {
        // Characterization, not aspiration (fuzzer-selftest-sut-landscape.md, item 5): the loop checks termination only between attempts, so a slow command overshoots the budget by however long its attempt takes, and a never-returning command hangs the run. This pins the current contract — the run returns and reports once the attempt completes — so any future mid-attempt abort mechanism shows up as this test getting faster.
        let adapter = __ExhaustRuntime.buildSequentialSpecAdapter(SlowCommandSpec.self, commandLimit: 2)
        let source = SyntheticCoverageSource<[(ScheduleMarker, SlowCommandSpec.Command)]>(
            edgeCount: 8,
            edges: { tagged in
                [tagged.count % 4]
            }
        )
        let start = ContinuousClock.now
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: adapter.generator,
            time: .milliseconds(100),
            settings: [.replay(3)],
            source: source,
            configure: { configuration in
                configuration.skipScreening = true
                configuration.reductionPoolWidth = 1
            },
            hooks: adapter.hooks,
            property: adapter.property
        )
        let elapsed = ContinuousClock.now - start
        #expect(report.totalAttempts >= 1)
        #expect(report.clusters.isEmpty, "the slow spec has no fault to find")
        #expect(elapsed >= .milliseconds(300), "a non-empty attempt sleeps at least 300 ms, past the 100 ms budget — the run cannot interrupt a property body mid-attempt")
    }

    @Test("Pruned corpus entries contain no skipped commands")
    func prunedCorpusHasNoSkips() {
        let adapter = __ExhaustRuntime.buildSequentialSpecAdapter(SkippableCounterSpec.self)
        let source = SyntheticCoverageSource<[(ScheduleMarker, SkippableCounterSpec.Command)]>(
            edgeCount: 16,
            edges: { tagged in
                var edges = [tagged.count % 8]
                let decrementCount = tagged.count { _, command in
                    if case .decrement = command {
                        return true
                    }
                    return false
                }
                if decrementCount > 0 {
                    edges.append(8 + (decrementCount % 4))
                }
                return edges
            }
        )
        var configuration = SprawlRunnerConfiguration(
            budgetNanoseconds: 60_000_000_000,
            seed: 42,
            skipScreening: true,
            attemptLimit: 300
        )
        configuration.reductionPoolWidth = 1

        let runner = SprawlRunner(
            gen: adapter.generator,
            property: adapter.property,
            source: source,
            configuration: configuration,
            hooks: adapter.hooks
        )
        let result = runner.run()
        #expect(result.corpusEntryCount > 0)

        let skipIdentifier = SkippableCounterSpec.skipIdentifier
        for index in runner.corpus.mutableTierIndices {
            let entry = runner.corpus.entries[index]
            guard case let .success(value, _, _) = Materializer.materialize(
                adapter.generator, prefix: entry.sequence, mode: .exact, fallbackTree: entry.tree
            ) else {
                continue
            }
            let commands = value.map(\.1)
            let skips = skipIdentifier(commands)
            #expect(skips.isEmpty, "Mutable-tier entry \(index) contains skipped commands at indices \(skips)")
        }
    }
}

// MARK: - Test Specs

struct PassingCounter {
    var value: Int = 0
    mutating func increment() {
        value += 1
    }
}

struct BoundedCounter {
    var value: Int = 0
    mutating func increment() {
        value += 1
    }
}

struct ThreadsCounter {
    var value: Int = 0
    mutating func increment() {
        value += 1
    }
}

struct TasksCounter {
    var value: Int = 0
    mutating func increment() {
        value += 1
    }
}

@StateMachine(.sequential)
final class AlwaysPassingSpec {
    var expected: Int = 0
    @SystemUnderTest var counter: PassingCounter = .init()

    @Command
    func increment() throws {
        expected += 1
        counter.increment()
    }

    @Invariant
    func valueMatchesCount() -> Bool {
        counter.value == expected
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

@StateMachine(.sequential)
final class FailsAtThreeSpec {
    var expected: Int = 0
    @SystemUnderTest var counter: BoundedCounter = .init()

    @Command
    func increment() throws {
        expected += 1
        counter.increment()
    }

    @Invariant
    func neverReachesThree() -> Bool {
        counter.value < 3
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

@StateMachine(.threads)
final class ThreadsCounterSpec {
    var expected: Int = 0
    @SystemUnderTest var counter: ThreadsCounter = .init()

    @Oracle
    func oracleMatches(other: ThreadsCounter) -> Bool {
        counter.value == other.value
    }

    @Command
    func increment() throws {
        expected += 1
        counter.increment()
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

@StateMachine(.tasks)
final class TasksCounterSpec {
    var expected: Int = 0
    @SystemUnderTest var counter: TasksCounter = .init()

    @Command
    func increment() throws {
        expected += 1
        counter.increment()
    }

    @Invariant
    func matches() -> Bool {
        counter.value == expected
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

@StateMachine(.sequential)
final class SlowCommandSpec {
    @SystemUnderTest var counter: PassingCounter = .init()

    @Command
    func slowIncrement() throws {
        Thread.sleep(forTimeInterval: 0.3)
        counter.increment()
    }

    @Invariant
    func neverNegative() -> Bool {
        counter.value >= 0
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

struct PlantedSpecError: Error {}

@StateMachine(.sequential)
final class ThrowingAtThreeSpec {
    var count: Int = 0
    @SystemUnderTest var counter: PassingCounter = .init()

    @Command
    func increment() throws {
        count += 1
        counter.increment()
        guard count < 3 else {
            throw PlantedSpecError()
        }
    }

    @Invariant
    func counterMatchesCount() -> Bool {
        counter.value == count
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

struct SkippableCounter {
    var value: Int = 0
    mutating func increment() {
        value += 1
    }

    mutating func decrement() {
        value -= 1
    }
}

@StateMachine(.sequential)
final class SkippableCounterSpec {
    var expected: Int = 0
    @SystemUnderTest var counter: SkippableCounter = .init()

    @Command(weight: 2)
    func increment() throws {
        expected += 1
        counter.increment()
    }

    @Command(weight: 2)
    func decrement() throws {
        guard expected > 0 else {
            throw skip()
        }
        expected -= 1
        counter.decrement()
    }

    @Invariant
    func valueMatchesExpected() -> Bool {
        counter.value == expected
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}
