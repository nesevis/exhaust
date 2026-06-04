import ExhaustTestSupport
import Testing
@testable import Exhaust

// MARK: - Tests

@Suite("Leaky bucket concurrent tests", .serialized, .tags(.contract))
struct LeakyBucketConcurrentTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Detects check-then-act bug that requires state buildup")
    func detectsCheckThenActBugThatRequiresStateBuildup() async throws {
        let result = try #require(
            await __ExhaustRuntime.__runContractConcurrent(
                LeakyBucketSpec.self,
                settings: [
                    .suppress(.issueReporting),
                ]
            )
        )
        let hasFailure = result.trace.contains { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        }
        #expect(hasFailure, "Should detect token over-drain from interleaved tryConsume")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Lane collapse encoder accepts probes when prefix is required")
    func laneCollapseEncoderAcceptsProbesWhenPrefixIsRequired() async throws {
        var deliveredReport: ExhaustReport?
        _ = await __ExhaustRuntime.__runContractConcurrent(
            LeakyBucketSpec.self,
            settings: [.commandLimit(8), .budget(.custom(coverage: 0, sampling: 500)), .replay(.numeric(42)), .suppress(.issueReporting), .onReport { deliveredReport = $0 }]
        )
        let report = try #require(deliveredReport)
        #expect(report.propertyInvocations == 19)
        #expect(report.reductionInvocations == 17)
        #expect(report.totalMaterializations == 23)
        #expect(report.cycles == 3)
        #expect(report.encoderProbes[.laneCollapse] == 9)
        #expect(report.encoderProbesAccepted[.laneCollapse] == 1)
        #expect(report.encoderProbes[.deletion] == 12)
        #expect(report.encoderProbes[.substitution] == 6)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Reports issue through Swift Testing when suppression is off")
    func reportsIssueThroughSwiftTestingWhenSuppressionIsOff() async {
        await withKnownIssue {
            let result = try #require(
                await __ExhaustRuntime.__runContractConcurrent(
                    LeakyBucketSpec.self,
                    settings: []
                )
            )
            let hasFailure = result.trace.contains { step in
                if case .invariantFailed = step.outcome { return true }
                return false
            }
            #expect(hasFailure)
        }
    }
}

// MARK: - Spec

@Contract(.tasks)
final class LeakyBucketSpec {
    @Model
    var expectedTokens: Int = 0
    @SystemUnderTest
    var bucket: LeakyBucket = .init(capacity: 5)

    @Invariant
    func tokensNeverNegative() -> Bool {
        bucket.tokens >= 0
    }

    @Invariant
    func matchesModel() -> Bool {
        bucket.tokens == expectedTokens
    }

    @Command(weight: 4)
    func refill() async throws {
        guard expectedTokens < 5 else { throw skip() }
        expectedTokens += 1
        await bucket.refill()
    }

    @Command(weight: 3)
    func tryConsume() async throws {
        guard expectedTokens > 0 else { throw skip() }
        expectedTokens -= 1
        await bucket.tryConsume()
    }
}
