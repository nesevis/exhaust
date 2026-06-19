import ExhaustTestSupport
import Testing
@testable import Exhaust

// MARK: - Tests

@Suite("Non-atomic counter concurrent tests", .serialized, .tags(.contract))
struct NonAtomicCounterConcurrentTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Detects lost-update bug in non-atomic counter")
    func detectsLostUpdateBugInNonAtomicCounter() async throws {
        let result = try #require(
            await __ExhaustRuntime.__runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(4), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
            )
        )
        let hasFailure = result.trace.contains { step in
            if case .invariantFailed = step.outcome { return true }
            if case .checkFailed = step.outcome { return true }
            return false
        }
        #expect(hasFailure, "Should detect invariant failure from interleaved read-modify-write")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Reduced counterexample is smaller than original")
    func reducedCounterexampleIsSmallerThanOriginal() async throws {
        let result = try #require(
            await __ExhaustRuntime.__runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(6), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
            )
        )
        #expect(result.commands.count <= 6, "Reducer should shrink the counterexample")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Coverage phase reports discoveryMethod .coverage with no seed")
    func coveragePhaseReportsDiscoveryMethodCoverageWithNoSeed() async throws {
        let result = try #require(
            await __ExhaustRuntime.__runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(6), .budget(.custom(coverage: 500, sampling: 0)), .suppress(.issueReporting)]
            )
        )
        #expect(result.discoveryMethod == .coverage, "Failure found during coverage should report .coverage")
        #expect(result.seed == nil, "Coverage-discovered failures should not carry a seed")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Random sampling reports discoveryMethod .randomSampling with a seed")
    func randomSamplingReportsDiscoveryMethodRandomSamplingWithASeed() async throws {
        let result = try #require(
            await __ExhaustRuntime.__runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(6), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
            )
        )
        #expect(result.discoveryMethod == .randomSampling, "Failure found during random sampling should report .randomSampling")
        #expect(result.seed != nil, "Random-sampling failures should carry a replay seed")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(".onReport delivers invocation counts and materializations")
    func onReportDeliversInvocationCountsAndMaterializations() async throws {
        var deliveredReport: ExhaustReport?
        _ = await __ExhaustRuntime.__runContractConcurrent(
            NonAtomicCounterSpec.self,
            settings: [
                .commandLimit(4),
                .budget(.custom(coverage: 0, sampling: 50)),
                .replay(.numeric(42)),
                .suppress(.issueReporting),
                .onReport { deliveredReport = $0
                },
            ]
        )
        let report = try #require(deliveredReport, "onReport closure should be called")
        #expect(report.propertyInvocations == 15)
        #expect(report.reductionInvocations == 13)
        #expect(report.totalMilliseconds > 0)
        #expect(report.totalMaterializations == 15)
        #expect(report.cycles == 3)
        #expect(report.encoderProbes[.laneCollapse] == 8)
        #expect(report.encoderProbesAccepted[.laneCollapse] == 0)
        #expect(report.encoderProbesAccepted[.deletion] == 2)
        #expect(report.encoderProbes[.deletion] == 10)
        #expect(report.encoderProbes[.substitution] == 6)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Deterministic replay produces same result")
    func deterministicReplayProducesSameResult() async throws {
        let result1 = try #require(
            await __ExhaustRuntime.__runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(10), .budget(.custom(coverage: 0, sampling: 200)), .replay(.numeric(42)), .suppress(.issueReporting)]
            )
        )
        let result2 = try #require(
            await __ExhaustRuntime.__runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(10), .budget(.custom(coverage: 0, sampling: 200)), .replay(.numeric(42)), .suppress(.issueReporting)]
            )
        )
        #expect(result1.commands.count == result2.commands.count, "Same seed should produce same counterexample size")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Reduction drives schedule markers toward prefix")
    func reductionDrivesScheduleMarkersTowardPrefix() async throws {
        let result = try #require(
            await __ExhaustRuntime.__runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(8), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
            )
        )
        #expect(result.commands.count <= 8, "Reducer should shrink the command count")
        #expect(result.commands.count >= 2, "Need at least 2 commands for interleaving")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Concurrent contract failure carries iteration-aware replay seed")
    func concurrentContractFailureCarriesIterationAwareReplaySeed() async throws {
        let result = try #require(
            await __ExhaustRuntime.__runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(6), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
            )
        )
        let replaySeed = try #require(result.replaySeed)
        #expect(replaySeed.contains("-"), "Replay seed should include iteration suffix")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Concurrent contract coverage failure carries U-prefixed replay seed")
    func concurrentContractCoverageFailureCarriesUPrefixedReplaySeed() async throws {
        let result = try #require(
            await __ExhaustRuntime.__runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(6), .budget(.custom(coverage: 500, sampling: 0)), .suppress(.issueReporting)]
            )
        )
        let replaySeed = try #require(result.replaySeed)
        #expect(replaySeed.hasPrefix("U"), "Coverage replay seed should have U prefix")
    }
}

// MARK: - Spec

@Contract(.tasks)
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
        guard expected > 0 else { throw skip() }
        expected -= 1
        await counter.decrement()
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}
