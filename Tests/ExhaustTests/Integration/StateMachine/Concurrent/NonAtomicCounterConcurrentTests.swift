import Exhaust
import ExhaustTestSupport
import Testing

// MARK: - Tests

@Suite("Non-atomic counter concurrent tests", .serialized, .tags(.stateMachine))
struct NonAtomicCounterConcurrentTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Detects lost-update bug in non-atomic counter")
    func detectsLostUpdateBugInNonAtomicCounter() async throws {
        let result = try #require(
            await #execute(
                NonAtomicCounterSpec.self,
                .commandLimit(4),
                .budget(.custom(screening: 0, sampling: 200)),
                .suppress(.issueReporting)
            )
        )
        let hasFailure = result.trace.contains { step in
            if case .invariantFailed = step.outcome {
                return true
            }
            if case .checkFailed = step.outcome {
                return true
            }
            return false
        }
        #expect(hasFailure, "Should detect invariant failure from interleaved read-modify-write")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Reduced counterexample is smaller than original")
    func reducedCounterexampleIsSmallerThanOriginal() async throws {
        let result = try #require(
            await #execute(
                NonAtomicCounterSpec.self,
                .commandLimit(6),
                .budget(.custom(screening: 0, sampling: 200)),
                .suppress(.issueReporting)
            )
        )
        #expect(result.commands.count <= 6, "Reducer should shrink the counterexample")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Screening phase reports discoveryMethod .screening with no seed")
    func screeningPhaseReportsDiscoveryMethodScreeningWithNoSeed() async throws {
        let result = try #require(
            await #execute(
                NonAtomicCounterSpec.self,
                .commandLimit(6),
                .budget(.custom(screening: 500, sampling: 0)),
                .suppress(.issueReporting)
            )
        )
        #expect(result.discoveryMethod == .screening, "Failure found during screening should report .screening")
        #expect(result.seed == nil, "Screening-discovered failures should not carry a seed")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Random sampling reports discoveryMethod .randomSampling with a seed")
    func randomSamplingReportsDiscoveryMethodRandomSamplingWithASeed() async throws {
        let result = try #require(
            await #execute(
                NonAtomicCounterSpec.self,
                .commandLimit(6),
                .budget(.custom(screening: 0, sampling: 200)),
                .suppress(.issueReporting)
            )
        )
        #expect(result.discoveryMethod == .randomSampling, "Failure found during random sampling should report .randomSampling")
        #expect(result.seed != nil, "Random-sampling failures should carry a replay seed")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(".onReport delivers invocation counts and materializations")
    func onReportDeliversInvocationCountsAndMaterializations() async throws {
        var deliveredReport: ExhaustReport?
        _ = await #execute(
            NonAtomicCounterSpec.self,
            .commandLimit(4),
            .budget(.custom(screening: 0, sampling: 50)),
            .replay(.numeric(42)),
            .suppress(.issueReporting),
            .onReport { deliveredReport = $0 }
        )
        let report = try #require(deliveredReport, "onReport closure should be called")
        #expect(report.propertyInvocations == 10)
        #expect(report.reductionInvocations == 7)
        #expect(report.totalMilliseconds > 0)
        #expect(report.totalMaterializations == 9)
        #expect(report.cycles == 5)
        #expect(report.encoderProbes[.laneCollapse] == 6)
        #expect(report.encoderProbesAccepted[.laneCollapse] == 0)
        #expect(report.encoderProbes[.deletion] == 9)
        #expect(report.encoderProbesAccepted[.deletion] == 2)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Deterministic replay produces same result")
    func deterministicReplayProducesSameResult() async throws {
        let result1 = try #require(
            await #execute(
                NonAtomicCounterSpec.self,
                .commandLimit(10),
                .budget(.custom(screening: 0, sampling: 200)),
                .replay(.numeric(42)),
                .suppress(.issueReporting)
            )
        )
        let result2 = try #require(
            await #execute(
                NonAtomicCounterSpec.self,
                .commandLimit(10),
                .budget(.custom(screening: 0, sampling: 200)),
                .replay(.numeric(42)),
                .suppress(.issueReporting)
            )
        )
        #expect(result1.commands.count == result2.commands.count, "Same seed should produce same counterexample size")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Reduction drives schedule markers toward prefix")
    func reductionDrivesScheduleMarkersTowardPrefix() async throws {
        let result = try #require(
            await #execute(
                NonAtomicCounterSpec.self,
                .commandLimit(8),
                .budget(.custom(screening: 0, sampling: 200)),
                .suppress(.issueReporting)
            )
        )
        #expect(result.commands.count <= 8, "Reducer should shrink the command count")
        #expect(result.commands.count >= 2, "Need at least 2 commands for interleaving")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Concurrent spec failure carries iteration-aware replay seed")
    func concurrentStateMachineFailureCarriesIterationAwareReplaySeed() async throws {
        let result = try #require(
            await #execute(
                NonAtomicCounterSpec.self,
                .commandLimit(6),
                .budget(.custom(screening: 0, sampling: 200)),
                .suppress(.issueReporting)
            )
        )
        let replaySeed = try #require(result.replaySeed)
        #expect(replaySeed.contains("-"), "Replay seed should include iteration suffix")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Concurrent spec screening failure carries U-prefixed replay seed")
    func concurrentStateMachineScreeningFailureCarriesUPrefixedReplaySeed() async throws {
        let result = try #require(
            await #execute(
                NonAtomicCounterSpec.self,
                .commandLimit(6),
                .budget(.custom(screening: 500, sampling: 0)),
                .suppress(.issueReporting)
            )
        )
        let replaySeed = try #require(result.replaySeed)
        #expect(replaySeed.hasPrefix("U"), "Screening replay seed should have U prefix")
    }
}

// MARK: - Spec

@StateMachine(.tasks)
final class NonAtomicCounterSpec {
    var expected: Int = 0
    @SystemUnderTest
    var counter: NonAtomicCounter = .init()

    @Invariant
    func matchesModel() -> Bool {
        counter.value == expected
    }

    @Command(weight: 3)
    func increment() async throws {
        expected += 1
        await counter.increment()
    }

    @Command(weight: 2)
    func decrement() async throws {
        guard expected > 0 else {
            throw skip()
        }
        expected -= 1
        await counter.decrement()
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}
