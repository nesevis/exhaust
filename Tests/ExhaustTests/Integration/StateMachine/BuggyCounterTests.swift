import Exhaust
import ExhaustTestSupport
import Testing

// MARK: - Tests

@Suite("Buggy counter state machine tests", .serialized, .tags(.stateMachine))
struct BuggyCounterTests {
    @Test("Detects model/SUT divergence in buggy counter")
    func detectsModelSUTDivergenceInBuggyCounter() async throws {
        let result = try #require(
            await #execute(
                BuggyCounterSpec.self,
                mode: .sequential,
                .commandLimit(10),
                .suppress(.issueReporting)
            )
        )
        // The trace should end with a failing step
        #expect(result.trace.last.map { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        } == true)

        // The SUT should be a BuggyCounter with capacity 3
        #expect(result.systemUnderTest?.capacity == 3)
    }

    @Test("Trace steps have correct structure")
    func traceStepsHaveCorrectStructure() async throws {
        let result = try #require(
            await #execute(
                BuggyCounterSpec.self,
                mode: .sequential,
                .commandLimit(10),
                .suppress(.issueReporting)
            )
        )

        // Every step should have a 1-based index
        for (offset, step) in result.trace.enumerated() {
            #expect(step.index == offset + 1)
        }

        // At least the last step should not be .ok (it's the failing step)
        if let lastStep = result.trace.last {
            if case .ok = lastStep.outcome {
                Issue.record("Last trace step should be a failure, not .ok")
            }
        }

        // Trace descriptions should be non-empty
        for step in result.trace {
            #expect(step.description.isEmpty == false)
        }
    }

    @Test("Sequential spec failure carries replay seed")
    func sequentialStateMachineFailureCarriesReplaySeed() async throws {
        let result = try #require(
            await #execute(
                BuggyCounterSpec.self,
                mode: .sequential,
                .commandLimit(10),
                .budget(.custom(screening: 0, sampling: 200)),
                .suppress(.issueReporting)
            )
        )
        #expect(result.replaySeed != nil, "Sampling failure should carry a replay seed")
        #expect(result.seed != nil, "Sampling failure should carry a PRNG seed")
    }

    @Test("Sequential spec SCA screening failure carries a U-marked replay seed")
    func sequentialStateMachineSCAScreeningFailureCarriesUMarkedReplaySeed() async throws {
        // A sampling-free budget forces the screening source, so the row-marker assertion always runs.
        let result = try #require(
            await #execute(
                BuggyCounterSpec.self,
                mode: .sequential,
                .commandLimit(4),
                .budget(.custom(screening: 200, sampling: 0)),
                .suppress(.issueReporting)
            )
        )
        #expect(result.discoveryMethod == .screening)
        let replaySeed = try #require(result.replaySeed)
        #expect(replaySeed.contains("-U"), "SCA screening replay seed should carry a U row marker")
    }
}

@Suite("SCA reduction screening", .serialized, .tags(.stateMachine))
struct SCAReductionScreeningTests {
    @Test("SCA screening exercises the reduction path")
    func scaScreeningExercisesReductionPath() async throws {
        let result = try #require(
            await #execute(
                PairwiseBugSpec.self,
                mode: .sequential,
                .commandLimit(3),
                .budget(.custom(screening: 200, sampling: 0)),
                .suppress(.issueReporting)
            )
        )
        #expect(result.discoveryMethod == .screening)
        #expect(result.trace.isEmpty == false)
    }

    @Test("SCA screening report counts reduction property invocations, not materializations")
    func scaScreeningReportCountsReductionPropertyInvocations() async throws {
        var capturedReport: ExhaustReport?
        let result = try #require(
            await #execute(
                PairwiseBugSpec.self,
                mode: .sequential,
                .commandLimit(3),
                .budget(.custom(screening: 200, sampling: 0)),
                .suppress(.issueReporting),
                .onReport { capturedReport = $0 }
            )
        )
        #expect(result.discoveryMethod == .screening)
        let report = try #require(capturedReport)
        #expect(report.screeningInvocations > 0)
        #expect(report.randomSamplingInvocations == 0)
        #expect(report.totalMaterializations >= report.reductionInvocations)
        #expect(report.propertyInvocations == report.screeningInvocations + report.reductionInvocations)
    }

    @Test("SCA screening report includes non-zero reduction timing")
    func scaScreeningReportIncludesReductionTiming() async throws {
        var capturedReport: ExhaustReport?
        let result = try #require(
            await #execute(
                PairwiseBugSpec.self,
                mode: .sequential,
                .commandLimit(3),
                .budget(.custom(screening: 200, sampling: 0)),
                .suppress(.issueReporting),
                .onReport { capturedReport = $0 }
            )
        )
        #expect(result.discoveryMethod == .screening)
        let report = try #require(capturedReport)
        #expect(report.reductionMilliseconds >= 0)
        #expect(report.totalMilliseconds >= report.reductionMilliseconds)
    }

    @Test("A screening replay seed reproduces the candidate it was emitted for")
    func screeningReplaySeedReproducesItsCandidate() async throws {
        let discovered = try #require(
            await #execute(
                PairwiseBugSpec.self,
                mode: .sequential,
                .commandLimit(3),
                .budget(.custom(screening: 200, sampling: 0)),
                .suppress(.issueReporting)
            )
        )
        #expect(discovered.discoveryMethod == .screening)
        let replaySeed = try #require(discovered.replaySeed)

        let replayed = try #require(
            await #execute(
                PairwiseBugSpec.self,
                mode: .sequential,
                .commandLimit(3),
                .budget(.custom(screening: 200, sampling: 0)),
                .replay(.encoded(replaySeed)),
                .suppress(.issueReporting)
            )
        )
        #expect(replayed.discoveryMethod == .screening)
        #expect(replayed.originalCommands?.map { "\($0)" } == discovered.originalCommands?.map { "\($0)" })
        #expect(replayed.commands.map { "\($0)" } == discovered.commands.map { "\($0)" })
    }

    @Test("A later-tier failure with generated arguments replays the same arguments")
    func laterTierFailureReplaysSameArguments() async throws {
        // The failure only fires past the fifth executed command, so it lands in the length-10 tier after the length-5 tier has already produced rows, and the replay must skip the length-5 tier entirely. The cooperative runner's screening domain is command-type-only, so the add argument is filled by the guided materializer's PRNG rather than the covering row: a materialization seed derived from work done in other tiers (rather than from the row's replay address) sends this red at the replay, which then reproduces nothing.
        let discovered = try #require(
            await #execute(
                LongSequenceArgumentBugSpec.self,
                mode: .tasks,
                .commandLimit(10),
                .budget(.custom(screening: 200, sampling: 0)),
                .suppress(.issueReporting)
            )
        )
        #expect(discovered.discoveryMethod == .screening)
        let replaySeed = try #require(discovered.replaySeed)
        #expect(replaySeed.hasSuffix("L10"), "The failure should come from the length-10 tier, got \(replaySeed)")

        let replayed = try #require(
            await #execute(
                LongSequenceArgumentBugSpec.self,
                mode: .tasks,
                .commandLimit(10),
                .budget(.custom(screening: 200, sampling: 0)),
                .replay(.encoded(replaySeed)),
                .suppress(.issueReporting)
            )
        )
        #expect(replayed.discoveryMethod == .screening)
        #expect(replayed.replaySeed == replaySeed)
        let discoveredOriginal = try #require(discovered.originalCommands)
        let replayedOriginal = try #require(replayed.originalCommands)
        #expect(replayedOriginal.map { "\($0)" } == discoveredOriginal.map { "\($0)" })
    }

    @Test("A filtered argument on the concurrent path survives screening and replays identically")
    func filteredArgumentSurvivesConcurrentScreening() async throws {
        // Command-type-only domains leave the add argument to the materializer's PRNG, and single-shot filtering would kill nearly every covering row. Retry keeps the rows alive, and the tier-skipping replay must reassemble the same arguments.
        let discovered = try #require(
            await #execute(
                FilteredArgumentConcurrentSpec.self,
                mode: .tasks,
                .commandLimit(10),
                .budget(.custom(screening: 200, sampling: 0)),
                .suppress(.issueReporting)
            )
        )
        #expect(discovered.discoveryMethod == .screening)
        let replaySeed = try #require(discovered.replaySeed)
        #expect(replaySeed.hasSuffix("L10"), "The failure should come from the length-10 tier, got \(replaySeed)")

        let replayed = try #require(
            await #execute(
                FilteredArgumentConcurrentSpec.self,
                mode: .tasks,
                .commandLimit(10),
                .budget(.custom(screening: 200, sampling: 0)),
                .replay(.encoded(replaySeed)),
                .suppress(.issueReporting)
            )
        )
        #expect(replayed.discoveryMethod == .screening)
        let discoveredOriginal = try #require(discovered.originalCommands)
        let replayedOriginal = try #require(replayed.originalCommands)
        #expect(replayedOriginal.map { "\($0)" } == discoveredOriginal.map { "\($0)" })
    }

    @Test("Screening starved by a filter warns and continues to random sampling")
    func filterStarvedScreeningWarnsAndContinues() async throws {
        // The filter precludes every representative the covering rows pin, so screening starves. That is legitimate: the run must warn, continue into sampling, and not fail.
        var capturedReport: ExhaustReport?
        var result: StateMachineResult<StarvedFilterSpec>?
        await withKnownIssue("Screening coverage loss is reported as a warning") {
            result = await #execute(
                StarvedFilterSpec.self,
                mode: .sequential,
                .commandLimit(6),
                .budget(.custom(screening: 60, sampling: 5)),
                .onReport { capturedReport = $0 }
            )
        }
        #expect(result == nil)
        let report = try #require(capturedReport)
        #expect(report.randomSamplingInvocations > 0)

        // Under suppression the same run must stay silent; an unsuppressed warning would fail this test.
        let suppressed = await #execute(
            StarvedFilterSpec.self,
            mode: .sequential,
            .commandLimit(6),
            .budget(.custom(screening: 60, sampling: 5)),
            .suppress(.issueReporting)
        )
        #expect(suppressed == nil)
    }

    @Test("A spec screening replay whose row no longer exists reports an error instead of passing")
    func specScreeningReplayMissingRowReportsError() async {
        // The length-3 tier saturates long before row 500, so the addressed row cannot exist: a stale pin must go red rather than pass as fixed.
        var result: StateMachineResult<PairwiseBugSpec>?
        await withKnownIssue("The replay cannot reach its addressed row") {
            result = await #execute(
                PairwiseBugSpec.self,
                mode: .sequential,
                .commandLimit(3),
                .budget(.custom(screening: 200, sampling: 0)),
                .replay(.encoded("19-U500L3"))
            )
        }
        #expect(result == nil)
    }
}

// MARK: - StateMachine

@StateMachine
final class BuggyCounterSpec {
    var expectedValue: Int = 0
    @SystemUnderTest var counter = BuggyCounter(capacity: 3)

    @Invariant
    func valueMatches() -> Bool {
        counter.value == expectedValue
    }

    @Command(weight: 3)
    func increment() throws {
        // Model uses capacity 5, SUT uses capacity 3 — diverges after 3 increments
        expectedValue = (expectedValue + 1) % 5
        counter.increment()
    }

    @Command(weight: 1)
    func reset() throws {
        expectedValue = 0
        counter.reset()
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

// MARK: - Types

/// A counter that wraps to zero after reaching a threshold. The bug: it wraps at 3 instead of the stated capacity of 5.
struct BuggyCounter {
    private(set) var value: Int = 0
    let capacity: Int

    mutating func increment() {
        value = (value + 1) % capacity
    }

    mutating func reset() {
        value = 0
    }
}

// MARK: - Pairwise Bug StateMachine

/// A spec where any sequence containing both `setA` and `setB` triggers the invariant failure. Pairwise SCA at t=2 is guaranteed to produce such a row.
@StateMachine
final class PairwiseBugSpec {
    var modelState: Int = 0
    @SystemUnderTest var sut = PairwiseBugSUT()

    @Invariant
    func notBothSet() -> Bool {
        sut.flagA == false || sut.flagB == false
    }

    @Command
    func setA() throws {
        sut.flagA = true
    }

    @Command
    func setB() throws {
        sut.flagB = true
    }

    @Command
    func noop() throws {}

    func failureDescription() -> String? {
        "\(sut)"
    }
}

struct PairwiseBugSUT {
    var flagA: Bool = false
    var flagB: Bool = false
}

// MARK: - Later-Tier Argument StateMachine

/// Loses updates only under overlapping lanes and only reports the loss past the fifth executed command, so the sequential smoke probe passes and a screening failure must come from the length-10 tier of the cooperative runner, whose command-type-only screening domains leave the add argument out of the covering row.
@StateMachine
private final class LongSequenceArgumentBugSpec {
    var executedCommands = 0
    var expectedTotal = 0
    @SystemUnderTest var sink = ArgumentSinkBox()

    @Command(weight: 2, .int(in: 1 ... 99))
    func add(value: Int) async throws {
        executedCommands += 1
        expectedTotal += value
        await sink.racyAdd(value)
    }

    @Command(weight: 1)
    func verify() throws {
        executedCommands += 1
        try check(executedCommands <= 5 || sink.total == expectedTotal, "lost an update past the fifth command")
    }

    func failureDescription() -> String? {
        "executed: \(executedCommands), expected: \(expectedTotal), total: \(sink.total)"
    }
}

private final class ArgumentSinkBox: @unchecked Sendable, CustomDebugStringConvertible {
    private(set) var total = 0

    /// Reads, suspends, then writes back, so two overlapping adds lose one of the updates.
    func racyAdd(_ amount: Int) async {
        let current = total
        await Task.yield()
        total = current + amount
    }

    var debugDescription: String {
        "ArgumentSinkBox(total: \(total))"
    }
}

// MARK: - Filtered Argument StateMachines

/// The racy shape of ``LongSequenceArgumentBugSpec`` with a filtered argument. `.tasks` covering rows do not pin the argument, and the one-in-ten pass rate compounded across ten positions kills essentially every row single-shot: screening discovers the later-tier failure only through the bounded retry.
@StateMachine
private final class FilteredArgumentConcurrentSpec {
    var executedCommands = 0
    var expectedTotal = 0
    @SystemUnderTest var sink = ArgumentSinkBox()

    @Command(weight: 2, .int(in: 1 ... 99).filter { @Sendable value in value % 10 == 5 })
    func add(value: Int) async throws {
        executedCommands += 1
        expectedTotal += value
        await sink.racyAdd(value)
    }

    @Command(weight: 1)
    func verify() throws {
        executedCommands += 1
        try check(executedCommands <= 5 || sink.total == expectedTotal, "lost an update past the fifth command")
    }

    func failureDescription() -> String? {
        "executed: \(executedCommands), expected: \(expectedTotal), total: \(sink.total)"
    }
}

/// The filter precludes every problematic-value representative of the 0...99 domain ({0, 1, 49, 98, 99}, none ending in 5), so covering rows containing a push die at the re-check and screening starves. Commands are `throws` for the failure channel; nothing throws, so every run passes.
@StateMachine
private final class StarvedFilterSpec {
    var total = 0
    @SystemUnderTest var sink = StarvedFilterSink()

    @Command(weight: 1, .int(in: 0 ... 99).filter { @Sendable value in value % 10 == 5 })
    func push(value: Int) throws {
        total += value
        sink.value += value
    }

    @Command(weight: 1)
    func reset() throws {
        total = 0
        sink.value = 0
    }

    func failureDescription() -> String? {
        nil
    }
}

private final class StarvedFilterSink {
    var value = 0
}
