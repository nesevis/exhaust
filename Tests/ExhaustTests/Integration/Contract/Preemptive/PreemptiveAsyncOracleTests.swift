import Exhaust
import Foundation
import Testing

/// Exercises an `async` `@Oracle` under the preemptive concurrent runner (PCCR).
///
/// The oracle reads SUT state through an asynchronous accessor, so the macro must synthesize an `async oracleCheck(_:)` and the runner must `await` it. A synchronous oracle never reaches that path.
@Suite("Preemptive concurrent contract: async @Oracle", .serialized, .tags(.contract))
struct PreemptiveAsyncOracleTests {
    @Test("Async oracle detects a lost-update race")
    func asyncOracleDetectsLostUpdateRace() async throws {
        let result = try #require(
            await #execute(
                AsyncOracleRacyCounterSpec.self,
                .concurrent(.two),
                .suppress(.issueReporting)
            )
        )
        #expect(result.commands.count >= 2, "Need at least 2 concurrent commands to trigger the race")
    }

    @Test("Async oracle passes for a thread-safe SUT")
    func asyncOraclePassesForThreadSafeSUT() async {
        let result = await #execute(
            AsyncOracleSafeCounterSpec.self,
            .concurrent(.two),
            .suppress(.issueReporting)
        )
        #expect(result == nil, "A serialized counter must never diverge from its sequential replay")
    }
}

// MARK: - Specs

@Contract(.threads)
final class AsyncOracleRacyCounterSpec {
    @SystemUnderTest
    var counter: AsyncRacyReadCounter = .init()

    /// Asynchronous oracle: both the concurrent SUT and the sequential reference are read through `snapshot()`, so the synthesized `oracleCheck` must `await` this method.
    @Oracle
    func valuesMatch(other: AsyncRacyReadCounter) async -> Bool {
        await counter.snapshot() == other.snapshot()
    }

    @Command(weight: 3)
    func increment() async throws {
        await counter.increment()
    }

    @Command(weight: 2)
    func decrement() async throws {
        guard await counter.snapshot() > 0 else { throw skip() }
        await counter.decrement()
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

@Contract(.threads)
final class AsyncOracleSafeCounterSpec {
    @SystemUnderTest
    var counter: AsyncSafeCounter = .init()

    @Oracle
    func valuesMatch(other: AsyncSafeCounter) async -> Bool {
        await counter.snapshot() == other.snapshot()
    }

    @Command(weight: 1)
    func increment() async throws {
        await counter.increment()
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

// MARK: - SUTs

/// Async facade over a deliberately racy counter. Reads and writes hop onto a concurrent `DispatchQueue` with no barriers, so read-modify-write sequences on different lanes interleave and lose updates.
final class AsyncRacyReadCounter: @unchecked Sendable, CustomDebugStringConvertible {
    private var _value: Int = 0
    private let queue = DispatchQueue(label: "async-oracle-racy-counter", attributes: .concurrent)

    var debugDescription: String {
        "AsyncRacyReadCounter(value: \(_value))"
    }

    func increment() async {
        await withCheckedContinuation { continuation in
            queue.async {
                let current = self._value
                Thread.sleep(forTimeInterval: 0.0001)
                self._value = current + 1
                continuation.resume()
            }
        }
    }

    func decrement() async {
        await withCheckedContinuation { continuation in
            queue.async {
                let current = self._value
                Thread.sleep(forTimeInterval: 0.0001)
                self._value = current - 1
                continuation.resume()
            }
        }
    }

    /// Asynchronous read, forcing any oracle that compares snapshots to be `async`.
    func snapshot() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self._value)
            }
        }
    }
}

/// Async facade over a serialized counter. All operations funnel through a serial queue, so concurrent lanes cannot lose updates and the final state always matches a sequential replay of the same commands.
final class AsyncSafeCounter: @unchecked Sendable, CustomDebugStringConvertible {
    private var _value: Int = 0
    private let queue = DispatchQueue(label: "async-oracle-safe-counter")

    var debugDescription: String {
        "AsyncSafeCounter(value: \(_value))"
    }

    func increment() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self._value += 1
                continuation.resume()
            }
        }
    }

    func snapshot() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self._value)
            }
        }
    }
}
