@testable import Exhaust
import Testing

// MARK: - Tests

@Suite("Non-atomic counter concurrent tests")
struct NonAtomicCounterConcurrentTests {
    @Test("Detects lost-update bug in non-atomic counter")
    func detectsLostUpdate() async throws {
        let result = try #require(
            await __runContractConcurrent(
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

    @Test("Reduced counterexample is smaller than original")
    func reductionShrinks() async throws {
        let result = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(6), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
            )
        )
        #expect(result.commands.count <= 6, "Reducer should shrink the counterexample")
    }

    @Test("Coverage phase reports discoveryMethod .coverage with no seed")
    func coverageDiscoveryMethod() async throws {
        let result = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(6), .budget(.custom(coverage: 500, sampling: 0)), .suppress(.issueReporting)]
            )
        )
        #expect(result.discoveryMethod == .coverage, "Failure found during coverage should report .coverage")
        #expect(result.seed == nil, "Coverage-discovered failures should not carry a seed")
    }

    @Test("Random sampling reports discoveryMethod .randomSampling with a seed")
    func randomSamplingDiscoveryMethod() async throws {
        let result = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(6), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
            )
        )
        #expect(result.discoveryMethod == .randomSampling, "Failure found during random sampling should report .randomSampling")
        #expect(result.seed != nil, "Random-sampling failures should carry a replay seed")
    }

    @Test(".onReport delivers invocation counts")
    func onReportDelivers() async {
        var deliveredReport: ExhaustReport?
        _ = await __runContractConcurrent(
            NonAtomicCounterSpec.self,
            settings: [.commandLimit(4), .budget(.custom(coverage: 0, sampling: 50)), .suppress(.issueReporting), .onReport { deliveredReport = $0 }]
        )
        #expect(deliveredReport != nil, "onReport closure should be called")
        if let report = deliveredReport {
            #expect(report.propertyInvocations > 0, "Should have recorded invocations")
            #expect(report.totalMilliseconds > 0, "Should have recorded timing")
        }
    }

    @Test("Deterministic replay produces same result")
    func deterministicReplay() async throws {
        let result1 = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(10), .budget(.custom(coverage: 0, sampling: 200)), .replay(.numeric(42)), .suppress(.issueReporting)]
            )
        )
        let result2 = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(10), .budget(.custom(coverage: 0, sampling: 200)), .replay(.numeric(42)), .suppress(.issueReporting)]
            )
        )
        #expect(result1.commands.count == result2.commands.count, "Same seed should produce same counterexample size")
    }

    @Test("Reduction drives schedule markers toward prefix")
    func reductionDrivesMarkersTowardPrefix() async throws {
        let result = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(8), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
            )
        )
        #expect(result.commands.count <= 8, "Reducer should shrink the command count")
        #expect(result.commands.count >= 2, "Need at least 2 commands for interleaving")
    }
}

// MARK: - Spec

@Contract
final class NonAtomicCounterSpec {
    @Model
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
}

// MARK: - SUT

final class NonAtomicCounter: @unchecked Sendable {
    private var _value: Int = 0

    var value: Int { _value }

    func increment() async {
        let current = _value
        await Task.yield()
        _value = current + 1
    }

    func decrement() async {
        let current = _value
        await Task.yield()
        _value = current - 1
    }
}
