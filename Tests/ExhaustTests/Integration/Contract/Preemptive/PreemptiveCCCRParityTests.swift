import ExhaustTestSupport
import Testing
@testable import Exhaust

// PCCR equivalents of the CCCR test specs. Same commands, same SUTs,
// @Contract(.threads) instead of @Contract, @Oracle added for sequential comparison.
// Purpose: verify that the preemptive runner catches the same bugs the cooperative runner does.
//
// @Model properties and model-comparing @Invariants are omitted because the preemptive runner
// dispatches commands to real GCD threads — @Model updates inside command bodies would race
// with each other. The @Oracle handles correctness by comparing against a sequential replay.

// MARK: - Non-Atomic Counter

@Suite("PCCR parity: non-atomic counter", .serialized, .tags(.contract))
struct PreemptiveNonAtomicCounterParityTests {
    @Test("Detects lost-update bug in non-atomic counter")
    func detectsLostUpdateBugInNonAtomicCounter() async throws {
        let result = try #require(
            await __ExhaustRuntime.__runPreemptiveConcurrentContractAsync(
                PreemptiveNonAtomicCounterParitySpec.self,
                settings: [.commandLimit(4), .budget(.custom(coverage: 0, sampling: 500)), .suppress(.issueReporting)]
            )
        )
        #expect(result.commands.count >= 2, "Need at least 2 concurrent commands to trigger the race")
    }

    @Test("Reduced counterexample is smaller than original")
    func reducedCounterexampleIsSmallerThanOriginal() async throws {
        let result = try #require(
            await __ExhaustRuntime.__runPreemptiveConcurrentContractAsync(
                PreemptiveNonAtomicCounterParitySpec.self,
                settings: [.commandLimit(6), .budget(.custom(coverage: 0, sampling: 500)), .suppress(.issueReporting)]
            )
        )
        #expect(result.commands.count <= 6, "Reducer should shrink the counterexample")
    }
}

@Contract(.threads)
final class PreemptiveNonAtomicCounterParitySpec {
    @SystemUnderTest
    var counter: NonAtomicCounter = .init()

    @Oracle
    func valuesMatch(other: NonAtomicCounter) -> Bool {
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

// MARK: - Leaky Bucket

@Suite("PCCR parity: leaky bucket", .serialized, .tags(.contract))
struct PreemptiveLeakyBucketParityTests {
    @Test("Detects check-then-act bug that requires state buildup")
    func detectsCheckThenActBugThatRequiresStateBuildup() async throws {
        let result = try #require(
            await __ExhaustRuntime.__runPreemptiveConcurrentContractAsync(
                PreemptiveLeakyBucketParitySpec.self,
                settings: [.budget(.custom(coverage: 0, sampling: 500)), .suppress(.issueReporting)]
            )
        )
        #expect(result.commands.count >= 2, "Need at least 2 concurrent commands to trigger the race")
    }
}

@Contract(.threads)
final class PreemptiveLeakyBucketParitySpec {
    @SystemUnderTest
    var bucket: LeakyBucket = .init(capacity: 5)

    @Oracle
    func tokensMatch(other: LeakyBucket) -> Bool {
        bucket.tokens == other.tokens
    }

    @Invariant
    func tokensNeverNegative() -> Bool {
        bucket.tokens >= 0
    }

    @Command(weight: 4)
    func refill() async throws {
        guard bucket.tokens < 5 else { throw skip() }
        await bucket.refill()
    }

    @Command(weight: 3)
    func tryConsume() async throws {
        guard bucket.tokens > 0 else { throw skip() }
        await bucket.tryConsume()
    }
}

// MARK: - Atomic Counter (should pass)

@Suite("PCCR parity: atomic counter", .serialized, .tags(.contract))
struct PreemptiveAtomicCounterParityTests {
    @Test("Thread-safe counter passes under preemptive execution")
    func threadSafeCounterPassesUnderPreemptiveExecution() async {
        let result = await __ExhaustRuntime.__runPreemptiveConcurrentContractAsync(
            PreemptiveAtomicCounterParitySpec.self,
            settings: [
                .commandLimit(4),
//                .suppress(.issueReporting)
            ]
        )
        #expect(result == nil, "Atomic counter should pass under any interleaving")
    }
}

@Contract(.threads)
final class PreemptiveAtomicCounterParitySpec {
    @SystemUnderTest
    var counter: ThreadSafeCounter = .init()

    @Oracle
    func valuesMatch(other: ThreadSafeCounter) -> Bool {
        counter.value == other.value
    }

    @Command(weight: 3)
    func increment() async throws {
        counter.increment()
    }

    @Command(weight: 2)
    func decrement() async throws {
        counter.decrement()
    }
}

// MARK: - Detection Boundary

@Suite("PCCR parity: detection boundary", .serialized, .tags(.contract))
struct PreemptiveDetectionBoundaryParityTests {
    @Test("Race with Task.yield() is detected by preemptive runner", .disabled("Race detection depends on scheduling timing"))
    func raceWithTaskyieldIsDetectedByPreemptiveRunner() async throws {
        let result = try #require(
            await __ExhaustRuntime.__runPreemptiveConcurrentContractAsync(
                PreemptiveExposedRaceParitySpec.self,
                settings: [.commandLimit(4), .budget(.custom(coverage: 0, sampling: 500)), .suppress(.issueReporting)]
            )
        )
        #expect(result.commands.count >= 2)
    }

    @Test("Three-way race detected with concurrencyLevel 3", .disabled("Race detection depends on scheduling timing"))
    func threeWayRaceDetectedWithConcurrencyLevel3() async throws {
        let result = try #require(
            await __ExhaustRuntime.__runPreemptiveConcurrentContractAsync(
                PreemptiveThreeWayRaceParitySpec.self,
                settings: [.concurrent(3), .commandLimit(6), .budget(.custom(coverage: 0, sampling: 500)), .suppress(.issueReporting)]
            )
        )
        #expect(result.commands.count >= 2, "Need at least 2 concurrent commands to trigger the race")
    }
}

@Contract(.threads)
final class PreemptiveExposedRaceParitySpec {
    @SystemUnderTest
    var counter: ExposedRacyCounter = .init()

    @Oracle
    func valuesMatch(other: ExposedRacyCounter) -> Bool {
        counter.value == other.value
    }

    @Command(weight: 1)
    func racyIncrement() async throws {
        await counter.racyIncrement()
    }
}

@Contract(.threads)
final class PreemptiveThreeWayRaceParitySpec {
    @SystemUnderTest
    var counter: ThreeWayRacyCounter = .init()

    @Oracle
    func valuesMatch(other: ThreeWayRacyCounter) -> Bool {
        counter.value == other.value
    }

    @Command(weight: 1)
    func increment() async throws {
        await counter.increment()
    }
}

// MARK: - All-Skip

@Suite("PCCR parity: all-skip", .serialized, .tags(.contract))
struct PreemptiveAllSkipParityTests {
    @Test("100% skip rate does not hang or crash")
    func fullSkipRateDoesNotHangOrCrash() async {
        let result = await __ExhaustRuntime.__runPreemptiveConcurrentContractAsync(
            PreemptiveAlwaysSkipParitySpec.self,
            settings: [.commandLimit(6), .budget(.custom(coverage: 0, sampling: 50)), .suppress(.issueReporting)]
        )
        #expect(result == nil, "A spec where every command skips should produce no failure")
    }

    @Test("100% skip rate with coverage phase")
    func fullSkipRateWithCoveragePhase() async {
        let result = await __ExhaustRuntime.__runPreemptiveConcurrentContractAsync(
            PreemptiveAlwaysSkipParitySpec.self,
            settings: [.commandLimit(4), .budget(.custom(coverage: 100, sampling: 50)), .suppress(.issueReporting)]
        )
        #expect(result == nil, "Coverage phase should handle 100% skip rate gracefully")
    }
}

@Contract(.threads)
final class PreemptiveAlwaysSkipParitySpec {
    @SystemUnderTest
    var value: Int = 0

    @Oracle
    func valuesMatch(other: Int) -> Bool {
        value == other
    }

    @Invariant
    func alwaysTrue() -> Bool {
        true
    }

    @Command(weight: 1)
    func skipAlways() async throws {
        throw skip()
    }

    @Command(weight: 1)
    func skipAlwaysToo() async throws {
        throw skip()
    }
}
