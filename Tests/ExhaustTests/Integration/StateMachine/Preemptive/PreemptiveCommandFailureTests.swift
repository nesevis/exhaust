import Exhaust
import ExhaustCore
import Testing

@Suite("Preemptive command failure propagation", .serialized, .tags(.stateMachine))
struct PreemptiveCommandFailureTests {
    @Test("Sync checker propagates failure from the selected execution phase", arguments: [false, true])
    func synchronous(prefix: Bool) {
        PostconditionOnlyCounter.reset()
        let commands: [(ScheduleMarker, SyncLaneFailingSpec.Command)] = [
            (prefix ? .prefix : ScheduleMarker(rawValue: 1), .fail),
            (ScheduleMarker(rawValue: 2), .noop),
        ]
        let outcome = PreemptiveChecker<SyncLaneFailingSpec>(idleTimeoutMilliseconds: nil).execute(
            commands, setupStep: nil, partition: LanePartition(markers: commands.map(\.0))
        )
        guard case let .failed(spec) = outcome else {
            Issue.record("Expected command failure, got \(outcome)")
            return
        }
        #expect(spec?.counter.calls.value == 1)
        #expect(PostconditionOnlyCounter.referenceCalls.value == (prefix ? 0 : 1))
    }

    @Test("Async checker propagates failure from the selected execution phase", arguments: [false, true])
    func asynchronous(prefix: Bool) {
        PostconditionOnlyCounter.reset()
        let commands: [(ScheduleMarker, AsyncLaneFailingSpec.Command)] = [
            (prefix ? .prefix : ScheduleMarker(rawValue: 1), .fail),
            (ScheduleMarker(rawValue: 2), .noop),
        ]
        let outcome = AsyncPreemptiveChecker<AsyncLaneFailingSpec>(idleTimeoutMilliseconds: nil).execute(
            commands, setupStep: nil, partition: LanePartition(markers: commands.map(\.0))
        )
        guard case let .failed(spec) = outcome else {
            Issue.record("Expected command failure, got \(outcome)")
            return
        }
        #expect(spec?.counter.calls.value == 1)
        #expect(PostconditionOnlyCounter.referenceCalls.value == (prefix ? 0 : 1))
    }
}

// MARK: - Specs

@StateMachine
final class SyncLaneFailingSpec {
    @SystemUnderTest var counter = PostconditionOnlyCounter()

    @Equivalence
    func alwaysPass(other _: PostconditionOnlyCounter) -> Bool {
        true
    }

    @Command
    func fail() throws {
        try check(counter.permitsCommand(), "injected command failure")
    }

    @Command
    func noop() throws {}

    func failureDescription() -> String? {
        "injected failure"
    }
}

@StateMachine
final class AsyncLaneFailingSpec {
    @SystemUnderTest var counter = PostconditionOnlyCounter()

    @Equivalence
    func alwaysPass(other _: PostconditionOnlyCounter) -> Bool {
        true
    }

    @Command
    func fail() async throws {
        try check(counter.permitsCommand(), "injected command failure")
    }

    @Command
    func noop() async throws {}

    func failureDescription() -> String? {
        "injected failure"
    }
}

// MARK: - Fixture

/// The checker constructs the concurrent instance first and its reference second.
/// Fail only the former: otherwise the reference rejects the commands before any lane runs.
final class PostconditionOnlyCounter: @unchecked Sendable {
    static let constructions = SendableBox(0)
    static let referenceCalls = SendableBox(0)
    let calls = SendableBox(0)
    let isConcurrent = constructions.withValue {
        $0 += 1
        return $0 == 1
    }

    static func reset() {
        constructions.value = 0
        referenceCalls.value = 0
    }

    func permitsCommand() -> Bool {
        calls.withValue { $0 += 1 }
        if isConcurrent == false {
            Self.referenceCalls.withValue { $0 += 1 }
        }
        return isConcurrent == false
    }
}
