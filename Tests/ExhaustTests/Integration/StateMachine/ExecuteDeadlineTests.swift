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
            .deadline(.milliseconds(100)), .replay(42), .suppress(.all), .onReport { report = $0 }
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
                .deadline(.milliseconds(100)), .suppress(.all), .onReport { report = $0 },
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
            .deadline(.milliseconds(100)), .suppress(.all), .onReport { report = $0 }
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

private func waitForExecuteDeadline() {
    Thread.sleep(forTimeInterval: 0.15)
}
