import Exhaust
import ExhaustCore
import Foundation
import Testing

@Suite("Preemptive command failure propagation", .serialized, .tags(.stateMachine))
struct PreemptiveCommandFailureTests {
    @Test("Public threads execution propagates a synchronous command throw from overlapping lanes")
    func synchronousLaneThrowReachesPublicAPI() async throws {
        let result = try #require(await #execute(
            SyncOverlappingCommandSpec.self,
            mode: .threads,
            .commandLimit(2),
            .budget(.custom(screening: 0, sampling: 30)),
            .replay(42),
            .suppress(.all)
        ))
        #expect(result.discoveryMethod == .randomSampling)
        #expect(result.commands.count >= 2)
        let counter = try #require(result.systemUnderTest)
        #expect(counter.didThrowFromOverlap)
    }

    @Test("Public threads execution propagates an asynchronous command throw from overlapping lanes")
    func asynchronousLaneThrowReachesPublicAPI() async throws {
        let result = try #require(await #execute(
            AsyncOverlappingCommandSpec.self,
            mode: .threads,
            .commandLimit(2),
            .budget(.custom(screening: 0, sampling: 30)),
            .replay(42),
            .suppress(.all)
        ))
        #expect(result.discoveryMethod == .randomSampling)
        #expect(result.commands.count >= 2)
        let counter = try #require(result.systemUnderTest)
        #expect(counter.didThrowFromOverlap)
    }

    @Test("Sync checker propagates failure from the selected execution phase", arguments: [ScheduleMarker.prefix, ScheduleMarker(rawValue: 1)])
    func synchronous(marker: ScheduleMarker) {
        PostconditionOnlyCounter.reset()
        let commands: [(ScheduleMarker, SyncLaneFailingSpec.Command)] = [
            (marker, .fail),
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
        #expect(PostconditionOnlyCounter.referenceCalls.value == (marker == .prefix ? 0 : 1))
    }

    @Test("Async checker propagates failure from the selected execution phase", arguments: [ScheduleMarker.prefix, ScheduleMarker(rawValue: 1)])
    func asynchronous(marker: ScheduleMarker) {
        PostconditionOnlyCounter.reset()
        let commands: [(ScheduleMarker, AsyncLaneFailingSpec.Command)] = [
            (marker, .fail),
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
        #expect(PostconditionOnlyCounter.referenceCalls.value == (marker == .prefix ? 0 : 1))
    }
}

// MARK: - Specs

@StateMachine
private final class SyncLaneFailingSpec {
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
private final class AsyncLaneFailingSpec {
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

@StateMachine
private final class SyncOverlappingCommandSpec {
    @SystemUnderTest var counter = OverlappingCommandCounter()

    @Equivalence
    func alwaysPass(other _: OverlappingCommandCounter) -> Bool {
        true
    }

    @Command
    func enter() throws {
        try counter.enter()
    }

    func failureDescription() -> String? {
        "overlapping command failure"
    }
}

@StateMachine
private final class AsyncOverlappingCommandSpec {
    @SystemUnderTest var counter = OverlappingCommandCounter()

    @Equivalence
    func alwaysPass(other _: OverlappingCommandCounter) -> Bool {
        true
    }

    @Command
    func enter() async throws {
        try counter.enter()
    }

    func failureDescription() -> String? {
        "overlapping command failure"
    }
}

// MARK: - Fixture

/// The checker constructs the concurrent instance first and its reference second.
/// Fail only the former: otherwise the reference rejects the commands before any lane runs.
private final class PostconditionOnlyCounter: @unchecked Sendable {
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

/// Sequential calls time out successfully; overlapping calls signal each other and throw.
/// The condition establishes overlap, while the bounded wait lets smoke and reference runs finish.
/// All mutable state is protected by the condition lock.
private final class OverlappingCommandCounter: @unchecked Sendable {
    private struct OverlapError: Error {}

    private let condition = NSCondition()
    private var activeCalls = 0
    private var hasOverlapped = false
    private var hasThrown = false

    var didThrowFromOverlap: Bool {
        condition.lock()
        defer { condition.unlock() }
        return hasThrown
    }

    func enter() throws {
        condition.lock()
        defer {
            activeCalls -= 1
            condition.unlock()
        }
        activeCalls += 1
        if activeCalls == 2 {
            hasOverlapped = true
            condition.broadcast()
        }
        let deadline = Date(timeIntervalSinceNow: 0.002)
        while hasOverlapped == false {
            if condition.wait(until: deadline) == false {
                return
            }
        }
        hasThrown = true
        throw OverlapError()
    }
}
