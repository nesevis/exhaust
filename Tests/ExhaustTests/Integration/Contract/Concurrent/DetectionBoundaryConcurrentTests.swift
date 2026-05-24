import ExhaustTestSupport
import Testing
@testable import Exhaust

// MARK: - Tests

@Suite("Detection boundary and multi-lane behavior", .serialized, .tags(.contract))
struct DetectionBoundaryTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Race without suspension point is NOT detected (demonstrates tool limitation)")
    func raceWithoutSuspensionPointIsNOTDetectedDemonstratesToolLimitation() async {
        let result = await __runContractConcurrent(
            SilentRaceSpec.self,
            settings: [.commandLimit(6), .budget(.custom(coverage: 0, sampling: 500)), .suppress(.issueReporting)]
        )
        #expect(result == nil, "Race without await/yield between read and write is invisible to cooperative scheduling")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Same race WITH suspension point IS detected")
    func sameRaceWITHSuspensionPointISDetected() async throws {
        let result = try #require(
            await __runContractConcurrent(
                ExposedRaceSpec.self,
                settings: [.commandLimit(4), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
            )
        )
        let hasFailure = result.trace.contains { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        }
        #expect(hasFailure, "Race with Task.yield() at the interleaving point should be detected")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Three-way race detected with concurrencyLevel 3")
    func threeWayRaceDetectedWithConcurrencyLevel3() async throws {
        let result = try #require(
            await __runContractConcurrent(
                ThreeWayRaceSpec.self,
                settings: [.concurrent(3), .commandLimit(6), .budget(.custom(coverage: 0, sampling: 500)), .suppress(.issueReporting)]
            )
        )
        let hasFailure = result.trace.contains { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        }
        #expect(hasFailure, "Three concurrent increments with yield should lose updates")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Four-way race detected with concurrencyLevel 4 (exercises chooseLaneControl)")
    func fourWayRaceDetectedWithConcurrencyLevel4ExercisesChooseLaneControl() async throws {
        let result = try #require(
            await __runContractConcurrent(
                ThreeWayRaceSpec.self,
                settings: [.concurrent(4), .commandLimit(8), .budget(.custom(coverage: 0, sampling: 500)), .suppress(.issueReporting)]
            )
        )
        let hasFailure = result.trace.contains { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        }
        #expect(hasFailure, "Four concurrent increments with yield should lose updates")
    }
}

// MARK: - Spec: Silent race (no suspension point at the race)

@Contract
final class SilentRaceSpec {
    @Model
    var expected: Int = 0
    @SystemUnderTest
    var counter: SilentlyRacyCounter = .init()

    @Invariant
    func matchesModel() -> Bool {
        counter.value == expected
    }

    @Command(weight: 1)
    func racyIncrement() async throws {
        expected += 1
        await counter.racyIncrement()
    }
}

// MARK: - Spec: Exposed race (yield at the race point)

@Contract
final class ExposedRaceSpec {
    @Model
    var expected: Int = 0
    @SystemUnderTest
    var counter: ExposedRacyCounter = .init()

    @Invariant
    func matchesModel() -> Bool {
        counter.value == expected
    }

    @Command(weight: 1)
    func racyIncrement() async throws {
        expected += 1
        await counter.racyIncrement()
    }
}

// MARK: - Spec: Three-way race (requires 3 lanes)

@Contract
final class ThreeWayRaceSpec {
    @Model
    var expected: Int = 0
    @SystemUnderTest
    var counter: ThreeWayRacyCounter = .init()

    @Invariant
    func matchesModel() -> Bool {
        counter.value == expected
    }

    @Command(weight: 1)
    func increment() async throws {
        expected += 1
        await counter.increment()
    }
}

// MARK: - SUT

/// Deliberately unsynchronized — @unchecked Sendable is required because the cooperative scheduler accesses the instance from multiple Tasks via SendableBox.
final class SilentlyRacyCounter: @unchecked Sendable {
    private var _value: Int = 0

    var value: Int {
        _value
    }

    func increment() async {
        _value += 1
    }

    func racyIncrement() async {
        let current = _value
        _value = current + 1
    }
}
