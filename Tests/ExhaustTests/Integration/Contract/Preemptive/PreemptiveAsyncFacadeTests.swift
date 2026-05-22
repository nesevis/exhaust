import Foundation
import Testing
@testable import Exhaust
import ExhaustTestSupport

@Suite("Preemptive concurrent contract: async facade over racy dispatch queue", .tags(.contract))
struct PreemptiveAsyncFacadeTests {
    @Test("Detects lost-update bug behind async facade")
    func detectsLostUpdate() async throws {
        let result = try #require(
            await __runPreemptiveConcurrentContractAsync(
                AsyncRacyCounterSpec.self,
                settings: [
                    .concurrency(2),
                    .commandLimit(6),
                    .budget(.custom(coverage: 0, sampling: 200)),
                    .suppress(.issueReporting),
                ]
            )
        )
        #expect(result.commands.count >= 2, "Need at least 2 concurrent commands to trigger the race")
    }

    @Test("onReport delivers profiling summary")
    func onReportDelivers() async throws {
        var capturedReport: ExhaustReport?
        _ = await __runPreemptiveConcurrentContractAsync(
            AsyncRacyCounterSpec.self,
            settings: [
                .concurrency(2),
                .commandLimit(6),
                .budget(.custom(coverage: 0, sampling: 200)),
                .suppress(.issueReporting),
                .onReport { capturedReport = $0 },
            ]
        )
        let report = try #require(capturedReport)
        #expect(report.totalMilliseconds > 0)
        #expect(report.propertyInvocations > 0)
        #expect(report.randomSamplingInvocations > 0)
    }

    @Test("Reports issue through Swift Testing when suppression is off")
    func reportsIssueThroughSwiftTesting() async {
        await withKnownIssue {
            _ = try #require(
                await __runPreemptiveConcurrentContractAsync(
                    AsyncRacyCounterSpec.self,
                    settings: [
                        .concurrency(2),
                        .commandLimit(6),
                        .budget(.custom(coverage: 0, sampling: 200)),
                    ]
                )
            )
        }
    }
}

// MARK: - Spec

@ConcurrentContract
final class AsyncRacyCounterSpec {
    @SystemUnderTest
    var counter: AsyncRacyCounter = .init()

    @Oracle
    func valuesMatch(other: AsyncRacyCounter) -> Bool {
        counter.value == other.value
    }

    @Invariant
    func isNonNegative() -> Bool {
        counter.value >= 0
    }

    @Command(weight: 3)
    func increment() async throws {
        await counter.increment()
    }

    @Command(weight: 2)
    func decrement() async throws {
        guard counter.value > 0 else { throw skip() }
        await counter.decrement()
    }
}

// MARK: - SUT

/// Async facade over a deliberately racy counter. The dispatch queue is concurrent with no barriers, so read-modify-write sequences on different lanes interleave freely — the same lost-update pattern as the synchronous variant, but invisible to the cooperative scheduler because the race is inside `DispatchQueue`, not at an `await` boundary.
final class AsyncRacyCounter: @unchecked Sendable, CustomDebugStringConvertible {
    private var _value: Int = 0
    private let queue = DispatchQueue(label: "racy-counter", attributes: .concurrent)

    var value: Int {
        _value
    }

    var debugDescription: String {
        "AsyncRacyCounter(value: \(_value))"
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
}
