import ExhaustTestSupport
import Foundation
import Testing
@testable import Exhaust

@Suite("Preemptive concurrent contract: non-atomic counter", .serialized, .tags(.contract))
struct PreemptiveNonAtomicCounterTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Detects lost-update bug via oracle comparison")
    func detectsLostUpdateBugViaOracleComparison() async throws {
        let result = try #require(
            await __ExhaustRuntime.dispatchToGCD {
                __runPreemptiveConcurrentContract(
                    PreemptiveCounterSpec.self,
                    settings: [
                        .concurrent(2),
                        .commandLimit(6),
                        .budget(.custom(coverage: 0, sampling: 200)),
                        .suppress(.issueReporting),
                    ]
                )
            }
        )
        #expect(result.commands.count >= 2, "Need at least 2 concurrent commands to trigger the race")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Failure report renders correctly")
    func failureReportRendersCorrectly() async throws {
        let result = try #require(
            await __ExhaustRuntime.dispatchToGCD {
                __runPreemptiveConcurrentContract(
                    PreemptiveCounterSpec.self,
                    settings: [
                        .concurrent(2),
                        .commandLimit(6),
                        .budget(.custom(coverage: 0, sampling: 200)),
                        .suppress(.issueReporting),
                    ]
                )
            }
        )
        #expect(result.commands.isEmpty == false)
        #expect(result.seed != nil)
        #expect(result.discoveryMethod == .randomSampling)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("onReport delivers profiling summary")
    func onReportDeliversProfilingSummary() async throws {
        var capturedReport: ExhaustReport?
        _ = await __ExhaustRuntime.dispatchToGCD {
            __runPreemptiveConcurrentContract(
                PreemptiveCounterSpec.self,
                settings: [
                    .concurrent(2),
                    .commandLimit(6),
                    .budget(.custom(coverage: 0, sampling: 200)),
                    .suppress(.issueReporting),
                    .onReport { capturedReport = $0 },
                ]
            )
        }
        let report = try #require(capturedReport)
        #expect(report.totalMilliseconds > 0)
        #expect(report.propertyInvocations > 0)
        #expect(report.randomSamplingInvocations > 0)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Reduction shrinks the counterexample")
    func reductionShrinksTheCounterexample() async throws {
        let result = try #require(
            await __ExhaustRuntime.dispatchToGCD {
                __runPreemptiveConcurrentContract(
                    PreemptiveCounterSpec.self,
                    settings: [
                        .concurrent(2),
                        .commandLimit(8),
                        .budget(.custom(coverage: 0, sampling: 200)),
                        .suppress(.issueReporting),
                    ]
                )
            }
        )
        #expect(result.commands.count <= 6, "Reducer should shrink from 8 commands")
        #expect(result.commands.count >= 2, "Need at least 2 concurrent commands")
    }
}

// MARK: - Spec

@ConcurrentContract
final class PreemptiveCounterSpec {
    @SystemUnderTest
    var counter: RacyCounter = .init()

    @Oracle
    func valuesMatch(other: RacyCounter) -> Bool {
        counter.value == other.value
    }

    @Invariant
    func isNonNegative() -> Bool {
        counter.value >= 0
    }

    @Command(weight: 3)
    func increment() throws {
        counter.increment()
    }

    @Command(weight: 2)
    func decrement() throws {
        guard counter.value > 0 else { throw skip() }
        counter.decrement()
    }
}

// MARK: - SUT

/// Deliberately unsynchronized counter. Concurrent increments lose updates because read-modify-write is not atomic.
final class RacyCounter: @unchecked Sendable, CustomDebugStringConvertible {
    private var _value: Int = 0

    var value: Int {
        _value
    }

    var debugDescription: String {
        "RacyCounter(value: \(_value))"
    }

    func increment() {
        let current = _value
        Thread.sleep(forTimeInterval: 0.0001)
        _value = current + 1
    }

    func decrement() {
        let current = _value
        Thread.sleep(forTimeInterval: 0.0001)
        _value = current - 1
    }
}
