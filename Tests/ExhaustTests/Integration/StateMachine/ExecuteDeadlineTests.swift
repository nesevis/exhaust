import ExhaustCore
import Foundation
import Testing
@testable import Exhaust

@Suite("Execute deadlines", .serialized, .tags(.stateMachine))
struct ExecuteDeadlineTests {
    @Test("Settings resolve the last deadline and saturate large durations")
    func deadlineResolution() {
        let expired = ResolvedConcurrentConfig.parse([.deadline(.seconds(60)), .deadline(.zero)]).config
        #expect(expired.hasExceededDeadline)
        let unlimited = ResolvedConcurrentConfig.parse([.deadline(.zero), .deadline(.nanoseconds(.max))]).config
        #expect(unlimited.deadlineNanoseconds == UInt64.max)
        #expect(unlimited.hasExceededDeadline == false)
    }

    @Test("Postponing the deadline returns the span a run spent waiting to be admitted")
    func deadlinePostponement() throws {
        var timed = ResolvedConcurrentConfig.parse([.deadline(.seconds(60))]).config
        let stamped = try #require(timed.deadlineNanoseconds)
        timed.postponeDeadline(by: 250_000_000)
        #expect(timed.deadlineNanoseconds == stamped + 250_000_000)

        // A run whose whole budget went to the gate gets it back rather than reporting a deadline it never used.
        var exhausted = ResolvedConcurrentConfig.parse([.deadline(.zero)]).config
        #expect(exhausted.hasExceededDeadline)
        exhausted.postponeDeadline(by: 60_000_000_000)
        #expect(exhausted.hasExceededDeadline == false)

        var saturated = ResolvedConcurrentConfig.parse([.deadline(.nanoseconds(.max))]).config
        saturated.postponeDeadline(by: 250_000_000)
        #expect(saturated.deadlineNanoseconds == UInt64.max)

        var untimed = ResolvedConcurrentConfig.parse([]).config
        untimed.postponeDeadline(by: 250_000_000)
        #expect(untimed.deadlineNanoseconds == nil)
    }

    @Test("A zero deadline executes no synchronous sequences")
    func zeroDeadline() async throws {
        var report: ExhaustReport?
        let result = await #execute(
            ExecuteDeadlineSyncSpec.self, mode: .sequential,
            .deadline(.zero), .suppress(.all), .onReport { report = $0 }
        )
        #expect(result == nil)
        let completed = try #require(report)
        #expect(completed.propertyInvocations == 0)
        #expect(completed.hasExceededDeadline)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("All async execution modes honor zero deadlines", arguments: [ExecutionModel.sequential, .tasks, .threads])
    func asyncZeroDeadline(mode: ExecutionModel) async throws {
        var report: ExhaustReport?
        let result = await __ExhaustRuntime.__runStateMachineDispatchAsync(
            ExecuteDeadlineAsyncSpec.self, mode: mode,
            settings: [.deadline(.zero), .suppress(.all), .onReport { report = $0 }]
        )
        #expect(result == nil)
        let completed = try #require(report)
        #expect(completed.propertyInvocations == 0)
        #expect(completed.hasExceededDeadline)
    }

    @Test("Screening and sampling stop after an in-flight sequence", arguments: [0, 50])
    func stopsBetweenSequences(screening: Int) async throws {
        var report: ExhaustReport?
        let result = await #execute(
            ExecuteDeadlineSyncSpec.self, mode: .sequential,
            .commandLimit(2), .budget(.custom(screening: screening, sampling: 1000)),
            .deadline(executeDeadline), .replay(42), .suppress(.all), .onReport { report = $0 }
        )
        #expect(result == nil)
        let completed = try #require(report)
        #expect(completed.hasExceededDeadline)
        #expect(completed.propertyInvocations > 0)
        #expect(completed.propertyInvocations < 1000)
        #expect(completed.reductionInvocations == 0)
        if screening > 0 {
            #expect(completed.screeningInvocations == 1)
            #expect(completed.randomSamplingInvocations == 0)
        }
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Concurrent modes finish the current probe before stopping", arguments: [ExecutionModel.tasks, .threads])
    func concurrentDeadline(mode: ExecutionModel) async throws {
        var report: ExhaustReport?
        let result = await __ExhaustRuntime.__runStateMachineDispatchAsync(
            ExecuteDeadlineAsyncSpec.self, mode: mode,
            settings: [
                .commandLimit(2), .budget(.custom(screening: 0, sampling: 1000)),
                .deadline(executeDeadline), .suppress(.all), .onReport { report = $0 },
            ]
        )
        #expect(result == nil)
        let completed = try #require(report)
        #expect(completed.hasExceededDeadline)
        #expect(completed.propertyInvocations == 1)
        #expect(completed.reductionInvocations == 0)
    }

    @Test("A failure discovered at the deadline is returned without reduction")
    func preservesFailure() async throws {
        var report: ExhaustReport?
        let result = await #execute(
            ExecuteDeadlineFailingSpec.self, mode: .sequential,
            .commandLimit(2), .budget(.custom(screening: 50, sampling: 1000)),
            .deadline(executeDeadline), .suppress(.all), .onReport { report = $0 }
        )
        #expect(result != nil)
        #expect(result?.commands.isEmpty == false)
        let completed = try #require(report)
        #expect(completed.hasExceededDeadline)
        #expect(completed.reductionWasCapped)
        #expect(completed.screeningInvocations == 1)
        #expect(completed.reductionInvocations == 0)
    }
}

@StateMachine
private final class ExecuteDeadlineSyncSpec {
    @SystemUnderTest var value: Int = 0

    func failureDescription() -> String? {
        nil
    }

    @Command func first() {
        waitForExecuteDeadline()
    }

    @Command func second() {
        waitForExecuteDeadline()
    }
}

@StateMachine
private final class ExecuteDeadlineAsyncSpec {
    @SystemUnderTest var value: ExecuteDeadlineSystem = .init()

    func failureDescription() -> String? {
        nil
    }

    @Equivalence
    func matches(other: ExecuteDeadlineSystem) -> Bool {
        value.number == other.number
    }

    @Command func first() async {
        await Task.yield()
        waitForExecuteDeadline()
    }

    @Command func second() async {
        await Task.yield()
        waitForExecuteDeadline()
    }
}

private final class ExecuteDeadlineSystem: Sendable {
    let number = 0
}

@StateMachine
private final class ExecuteDeadlineFailingSpec {
    @SystemUnderTest var value: Int = 0

    func failureDescription() -> String? {
        nil
    }

    @Command func first() throws {
        waitForExecuteDeadline()
        try check(false, "Expected failure")
    }

    @Command func second() throws {
        waitForExecuteDeadline()
        try check(false, "Expected failure")
    }
}

/// Milliseconds of wall clock a deadline test grants its run.
///
/// Three times the budget these tests originally used. The deadline clock starts when the settings are parsed, so everything before the first probe (spec validation, backend construction, the hop onto a worker) is charged to it, and a slow CI machine can spend longer there than a tight budget allows. A run that reaches its deadline before probing reports zero invocations, which is indistinguishable from the run stopping too early.
private let executeDeadlineMilliseconds = 300

/// The wall-clock budget passed to every deadline test that expects its run to reach one.
private let executeDeadline = TimeSpan.milliseconds(executeDeadlineMilliseconds)

/// Blocks for half again the run's budget, so one command overruns the deadline on its own.
///
/// The counts these tests assert depend on that ratio rather than on the absolute durations: a sequence that starts before the deadline always crosses it inside its first command, so exactly one screening row or one property invocation is in flight when the run stops.
private func waitForExecuteDeadline() {
    Thread.sleep(forTimeInterval: Double(executeDeadlineMilliseconds) * 1.5 / 1000)
}
