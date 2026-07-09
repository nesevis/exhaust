import Exhaust
import ExhaustTestSupport
import Foundation
import Testing

@Suite("Preemptive concurrent spec: non-atomic counter", .serialized, .tags(.stateMachine))
struct PreemptiveNonAtomicCounterTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Detects lost-update bug via oracle comparison")
    func detectsLostUpdateBugViaOracleComparison() async throws {
        let result = try #require(
            await #execute(
                PreemptiveCounterSpec.self,
                .parallelize(lanes: .two),
                .commandLimit(6),
                .budget(.custom(coverage: 0, sampling: 200)),
                .suppress(.issueReporting)
            )
        )
        #expect(result.commands.count >= 2, "Need at least 2 concurrent commands to trigger the race")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Failure report renders correctly")
    func failureReportRendersCorrectly() async throws {
        let result = try #require(
            await #execute(
                PreemptiveCounterSpec.self,
                .parallelize(lanes: .two),
                .commandLimit(6),
                .budget(.custom(coverage: 0, sampling: 200)),
                .suppress(.issueReporting)
            )
        )
        #expect(result.commands.isEmpty == false)
        #expect(result.seed != nil)
        #expect(result.discoveryMethod == .randomSampling)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("onReport delivers profiling summary")
    func onReportDeliversProfilingSummary() async throws {
        var capturedReport: ExhaustReport?
        _ = await #execute(
            PreemptiveCounterSpec.self,
            .parallelize(lanes: .two),
            .commandLimit(6),
            .budget(.custom(coverage: 0, sampling: 200)),
            .suppress(.issueReporting),
            .onReport { capturedReport = $0 }
        )
        let report = try #require(capturedReport)
        #expect(report.totalMilliseconds > 0)
        #expect(report.propertyInvocations > 0)
        #expect(report.randomSamplingInvocations > 0)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Reduction shrinks the counterexample")
    func reductionShrinksTheCounterexample() async throws {
        let result = try #require(
            await #execute(
                PreemptiveCounterSpec.self,
                .parallelize(lanes: .two),
                .commandLimit(20),
                .suppress(.issueReporting)
            )
        )
        #expect((result.originalCommands?.count ?? 0) >= result.commands.count, "Reducer should shrink commands")
    }
}

// MARK: - Spec

@StateMachine(.threads)
final class PreemptiveCounterSpec {
    @SystemUnderTest
    var counter: RacyCounter = .init()

    @Oracle
    func valuesMatch(other: RacyCounter) -> Bool {
        counter.value == other.value
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

    func failureDescription() -> String? {
        "\(counter)"
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
