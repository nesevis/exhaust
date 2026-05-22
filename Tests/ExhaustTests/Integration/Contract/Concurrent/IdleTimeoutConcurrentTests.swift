import ExhaustTestSupport
import Testing
@testable import Exhaust

// MARK: - Tests

@Suite("Idle timeout concurrent tests", .serialized, .tags(.contract))
struct IdleTimeoutConcurrentTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test
    func `Idle timeout fires for SUT that escapes the cooperative executor`() async throws {
        let result = try #require(
            await __runContractConcurrent(
                SleepingSpec.self,
                settings: [.commandLimit(2), .idleTimeoutMs(10), .budget(.custom(coverage: 0, sampling: 10)), .suppress(.issueReporting)]
            )
        )
        #expect(result.discoveryMethod == .randomSampling)
    }
}

// MARK: - Spec

@Contract
final class SleepingSpec {
    @Model
    var count: Int = 0
    @SystemUnderTest
    var counter: SleepingCounter = .init()

    @Invariant
    func alwaysTrue() -> Bool {
        true
    }

    @Command(weight: 1)
    func doSleep() async throws {
        count += 1
        await counter.sleepAndIncrement()
    }
}

// MARK: - SUT

/// Deliberately unsynchronized — @unchecked Sendable is required because the cooperative scheduler accesses the instance from multiple Tasks via SendableBox.
final class SleepingCounter: @unchecked Sendable {
    private var _value: Int = 0
    var value: Int {
        _value
    }

    func sleepAndIncrement() async {
        try? await Task.sleep(for: .milliseconds(200))
        _value += 1
    }
}
