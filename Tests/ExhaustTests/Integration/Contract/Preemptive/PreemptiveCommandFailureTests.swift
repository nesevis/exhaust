import Exhaust
import Foundation
import Testing

@Suite("Preemptive concurrent contract: command-level failures", .serialized, .tags(.contract))
struct PreemptiveCommandFailureTests {
    @Test("Sync checker detects postcondition failure in prefix command")
    func syncCheckerDetectsPostconditionFailureInPrefixCommand() throws {
        let result = try #require(
            #execute(
                SyncPrefixFailingSpec.self,
                .concurrent(.two),
                .suppress(.all)
            )
        )
        #expect(result.commands.isEmpty == false)
    }

    @Test("Sync checker detects postcondition failure in concurrent lane")
    func syncCheckerDetectsPostconditionFailureInConcurrentLane() throws {
        let result = try #require(
            #execute(
                SyncLaneFailingSpec.self,
                .concurrent(.two),
                .suppress(.all)
            )
        )
        #expect(result.commands.isEmpty == false)
    }

    @Test("Async checker detects postcondition failure in prefix command")
    func asyncCheckerDetectsPostconditionFailureInPrefixCommand() async throws {
        let result = try #require(
            await #execute(
                AsyncPrefixFailingSpec.self,
                .concurrent(.two),
                .suppress(.all)
            )
        )
        #expect(result.commands.isEmpty == false)
    }

    @Test("Async checker detects postcondition failure in concurrent lane")
    func asyncCheckerDetectsPostconditionFailureInConcurrentLane() async throws {
        let result = try #require(
            await #execute(
                AsyncLaneFailingSpec.self,
                .concurrent(.two),
                .suppress(.all)
            )
        )
        #expect(result.commands.isEmpty == false)
    }
}

// MARK: - Sync Specs

/// Prefix command throws a postcondition failure after three increments.
/// No invariant — the only failure path is the throw from `run(_:)`.
@Contract(.threads)
final class SyncPrefixFailingSpec {
    @SystemUnderTest var counter: PostconditionOnlyCounter = .init(threshold: 3)

    @Oracle
    func alwaysPass(other _: PostconditionOnlyCounter) -> Bool {
        true
    }

    @Command(weight: 1)
    func increment() throws {
        counter.increment()
        try check(counter.value < counter.threshold, "value must stay below threshold")
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

/// Concurrent lane command throws a postcondition failure. The oracle always passes —
/// without proper error propagation from `run(_:)`, the failure is invisible.
@Contract(.threads)
final class SyncLaneFailingSpec {
    @SystemUnderTest var counter: PostconditionOnlyCounter = .init(threshold: 3)

    @Oracle
    func alwaysPass(other _: PostconditionOnlyCounter) -> Bool {
        true
    }

    @Command(weight: 3)
    func increment() throws {
        counter.increment()
        try check(counter.value < counter.threshold, "value must stay below threshold")
    }

    @Command(weight: 1)
    func noop() throws {}

    func failureDescription() -> String? {
        "\(counter)"
    }
}

// MARK: - Async Specs

/// Async variant: prefix command throws a postcondition failure.
@Contract(.threads)
final class AsyncPrefixFailingSpec {
    @SystemUnderTest var counter: PostconditionOnlyCounter = .init(threshold: 3)

    @Oracle
    func alwaysPass(other _: PostconditionOnlyCounter) -> Bool {
        true
    }

    @Command(weight: 1)
    func increment() async throws {
        counter.increment()
        try check(counter.value < counter.threshold, "value must stay below threshold")
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

/// Async variant: concurrent lane command throws a postcondition failure.
@Contract(.threads)
final class AsyncLaneFailingSpec {
    @SystemUnderTest var counter: PostconditionOnlyCounter = .init(threshold: 3)

    @Oracle
    func alwaysPass(other _: PostconditionOnlyCounter) -> Bool {
        true
    }

    @Command(weight: 3)
    func increment() async throws {
        counter.increment()
        try check(counter.value < counter.threshold, "value must stay below threshold")
    }

    @Command(weight: 1)
    func noop() async throws {}

    func failureDescription() -> String? {
        "\(counter)"
    }
}

// MARK: - Types

/// Counter with no thread safety. The only failure mechanism is the postcondition
/// check inside each command — no invariant, no oracle divergence.
final class PostconditionOnlyCounter: @unchecked Sendable, CustomDebugStringConvertible {
    private(set) var value: Int = 0
    let threshold: Int

    init(threshold: Int) {
        self.threshold = threshold
    }

    var debugDescription: String {
        "PostconditionOnlyCounter(value: \(value), threshold: \(threshold))"
    }

    func increment() {
        value += 1
    }
}
