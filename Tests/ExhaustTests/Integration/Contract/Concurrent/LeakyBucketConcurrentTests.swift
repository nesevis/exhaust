import Testing
@testable import Exhaust

// MARK: - Tests

@Suite("Leaky bucket concurrent tests")
struct LeakyBucketConcurrentTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Detects check-then-act bug that requires state buildup")
    func detectsLeakyBucket() async throws {
        let result = try #require(
            await __runContractConcurrent(
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
    @Test("Reports issue through Swift Testing when suppression is off")
    func reportsIssueThroughSwiftTesting() async {
        await withKnownIssue {
            let result = try #require(
                await __runContractConcurrent(
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

@Contract
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

// MARK: - SUT

/// Deliberately unsynchronized — @unchecked Sendable is required because the cooperative scheduler accesses the instance from multiple Tasks via SendableBox.
final class LeakyBucket: @unchecked Sendable {
    private var _tokens: Int = 0
    private let _capacity: Int

    init(capacity: Int) {
        _capacity = capacity
    }

    var tokens: Int {
        _tokens
    }

    func refill() async {
        guard _tokens < _capacity else { return }
        _tokens += 1
    }

    func tryConsume() async {
        let current = _tokens
        guard current > 0 else { return }
        await Task.yield()
        _tokens = current - 1
    }
}
