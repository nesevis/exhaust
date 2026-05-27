import ExhaustTestSupport
import Foundation
import Testing
@testable import Exhaust

@Suite("Preemptive concurrent contract: command-level failures", .serialized, .tags(.contract))
struct PreemptiveCommandFailureTests {
    @Test("Sync checker detects postcondition failure in prefix command")
    func syncCheckerDetectsPostconditionFailureInPrefixCommand() async throws {
        let result = try #require(
            await __ExhaustRuntime.dispatchToGCD {
                __runPreemptiveConcurrentContract(
                    SyncPrefixFailingSpec.self,
                    settings: [
                        .concurrent(2),
                        .commandLimit(4),
                        .budget(.custom(coverage: 0, sampling: 200)),
                        .suppress(.all),
                    ]
                )
            }
        )
        #expect(result.commands.isEmpty == false)
    }

    @Test("Sync checker detects postcondition failure in concurrent lane")
    func syncCheckerDetectsPostconditionFailureInConcurrentLane() async throws {
        let result = try #require(
            await __ExhaustRuntime.dispatchToGCD {
                __runPreemptiveConcurrentContract(
                    SyncLaneFailingSpec.self,
                    settings: [
                        .concurrent(2),
                        .commandLimit(6),
                        .budget(.custom(coverage: 0, sampling: 200)),
                        .suppress(.all),
                    ]
                )
            }
        )
        #expect(result.commands.isEmpty == false)
    }

    @Test("Async checker detects postcondition failure in prefix command")
    func asyncCheckerDetectsPostconditionFailureInPrefixCommand() async throws {
        let result = try #require(
            await __runPreemptiveConcurrentContractAsync(
                AsyncPrefixFailingSpec.self,
                settings: [
                    .concurrent(2),
                    .commandLimit(4),
                    .budget(.custom(coverage: 0, sampling: 200)),
                    .suppress(.all),
                ]
            )
        )
        #expect(result.commands.isEmpty == false)
    }

    @Test("Async checker detects postcondition failure in concurrent lane")
    func asyncCheckerDetectsPostconditionFailureInConcurrentLane() async throws {
        let result = try #require(
            await __runPreemptiveConcurrentContractAsync(
                AsyncLaneFailingSpec.self,
                settings: [
                    .concurrent(2),
                    .commandLimit(6),
                    .budget(.custom(coverage: 0, sampling: 200)),
                    .suppress(.all),
                ]
            )
        )
        #expect(result.commands.isEmpty == false)
    }
}

// MARK: - Sync Specs

/// Prefix command throws a postcondition failure after three increments.
/// No invariant — the only failure path is the throw from `run(_:)`.
@ConcurrentContract
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
}

/// Concurrent lane command throws a postcondition failure. The oracle always passes —
/// without proper error propagation from `run(_:)`, the failure is invisible.
@ConcurrentContract
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
}

// MARK: - Async Specs

/// Async variant: prefix command throws a postcondition failure.
@ConcurrentContract
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
}

/// Async variant: concurrent lane command throws a postcondition failure.
@ConcurrentContract
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
