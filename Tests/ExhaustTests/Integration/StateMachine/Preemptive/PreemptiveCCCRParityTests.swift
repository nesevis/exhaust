import Exhaust
import Testing

// PCCR equivalents of the CCCR test specs. Same commands, same SUTs,
// @StateMachine instead of @StateMachine, @Equivalence added for sequential comparison.
// Purpose: verify that the preemptive runner catches the same bugs the cooperative runner does.
//
// properties and model-comparing @Invariants are omitted because the preemptive runner
// dispatches commands to real GCD threads — updates inside command bodies would race
// with each other. The @Equivalence handles correctness by comparing against a sequential replay.

// MARK: - Non-Atomic Counter

@Suite("PCCR parity: non-atomic counter", .serialized, .tags(.stateMachine))
struct PreemptiveNonAtomicCounterParityTests {
    @Test("Detects lost-update bug in non-atomic counter")
    func detectsLostUpdateBugInNonAtomicCounter() async {
        let result = await #execute(
            PreemptiveNonAtomicCounterParitySpec.self,
            mode: .threads,
            .suppress(.issueReporting),
            .budget(.extensive)
        )
        #expect(result != nil, "Should never pass")
    }
}

@StateMachine
final class PreemptiveNonAtomicCounterParitySpec {
    @SystemUnderTest
    var counter: NonAtomicCounter = .init()

    @Equivalence
    func valuesMatch(other: NonAtomicCounter) -> Bool {
        counter.value == other.value
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

    func failureDescription() -> String? {
        "\(counter)"
    }
}

// MARK: - Leaky Bucket

@Suite("PCCR parity: leaky bucket", .serialized, .tags(.stateMachine))
struct PreemptiveLeakyBucketParityTests {
    @Test("Detects check-then-act bug that requires state buildup")
    func detectsCheckThenActBugThatRequiresStateBuildup() async {
        let result = await #execute(
            PreemptiveLeakyBucketParitySpec.self,
            mode: .threads,
            .suppress(.issueReporting),
            .budget(.extensive)
        )
        #expect(result != nil, "Should never pass")
        if let result {
            #expect(result.commands.count >= 2, "Need at least 2 concurrent commands to trigger the race")
        }
    }
}

@StateMachine
final class PreemptiveLeakyBucketParitySpec {
    @SystemUnderTest
    var bucket: LeakyBucket = .init(capacity: 5)

    @Equivalence
    func tokensMatch(other: LeakyBucket) -> Bool {
        bucket.tokens == other.tokens
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

    func failureDescription() -> String? {
        "\(bucket)"
    }
}

// MARK: - Atomic Counter (should pass)

@Suite("PCCR parity: atomic counter", .serialized, .tags(.stateMachine))
struct PreemptiveAtomicCounterParityTests {
    @Test("Thread-safe counter passes under preemptive execution")
    func threadSafeCounterPassesUnderPreemptiveExecution() async {
        let result = await #execute(
            PreemptiveAtomicCounterParitySpec.self,
            mode: .threads,
            .suppress(.issueReporting)
        )
        #expect(result == nil, "Atomic counter should pass under any interleaving")
    }
}

@StateMachine
final class PreemptiveAtomicCounterParitySpec {
    @SystemUnderTest
    var counter: ThreadSafeCounter = .init()

    @Equivalence
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

    func failureDescription() -> String? {
        "\(counter)"
    }
}

// MARK: - Detection Boundary

@Suite("PCCR parity: detection boundary", .serialized, .tags(.stateMachine))
struct PreemptiveDetectionBoundaryParityTests {
    @Test("Race with Task.yield() is detected by preemptive runner")
    func raceWithTaskyieldIsDetectedByPreemptiveRunner() async throws {
        let result = try #require(
            await #execute(
                PreemptiveExposedRaceParitySpec.self,
                mode: .threads,
                .suppress(.issueReporting),
                .budget(.extensive)
            )
        )
        #expect(result.commands.count >= 2)
    }

    @Test("Three-way race detected with concurrencyLevel 3")
    func threeWayRaceDetectedWithConcurrencyLevel3() async throws {
        let result = try #require(
            await #execute(
                PreemptiveThreeWayRaceParitySpec.self,
                mode: .threads,
                .parallelize(lanes: .three),
                .suppress(.issueReporting),
                .budget(.extensive)
            )
        )
        #expect(result.commands.count >= 2, "Need at least 2 concurrent commands to trigger the race")
    }
}

@StateMachine
final class PreemptiveExposedRaceParitySpec {
    @SystemUnderTest
    var counter: ExposedRacyCounter = .init()

    @Equivalence
    func valuesMatch(other: ExposedRacyCounter) -> Bool {
        counter.value == other.value
    }

    @Command(weight: 1)
    func racyIncrement() async throws {
        await counter.racyIncrement()
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

@StateMachine
final class PreemptiveThreeWayRaceParitySpec {
    @SystemUnderTest
    var counter: ThreeWayRacyCounter = .init()

    @Equivalence
    func valuesMatch(other: ThreeWayRacyCounter) -> Bool {
        counter.value == other.value
    }

    @Command(weight: 1)
    func increment() async throws {
        await counter.increment()
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

// MARK: - All-Skip

@Suite("PCCR parity: all-skip", .serialized, .tags(.stateMachine))
struct PreemptiveAllSkipParityTests {
    @Test("100% skip rate does not hang or crash")
    func fullSkipRateDoesNotHangOrCrash() async {
        let result = await #execute(
            PreemptiveAlwaysSkipParitySpec.self,
            mode: .threads,
            .suppress(.issueReporting)
        )
        #expect(result == nil, "A spec where every command skips should produce no failure")
    }

    @Test("100% skip rate with screening phase")
    func fullSkipRateWithScreeningPhase() async {
        let result = await #execute(
            PreemptiveAlwaysSkipParitySpec.self,
            mode: .threads,
            .suppress(.issueReporting)
        )
        #expect(result == nil, "Screening phase should handle 100% skip rate gracefully")
    }
}

@StateMachine
final class PreemptiveAlwaysSkipParitySpec {
    @SystemUnderTest
    var counter: SkipOnlyCounter = .init()

    @Equivalence
    func valuesMatch(other: SkipOnlyCounter) -> Bool {
        counter.value == other.value
    }

    @Command(weight: 1)
    func skipAlways() async throws {
        throw skip()
    }

    @Command(weight: 1)
    func skipAlwaysToo() async throws {
        throw skip()
    }

    func failureDescription() -> String? {
        "\(counter.value)"
    }
}

/// A system under test nothing ever calls, for the spec whose every command skips. A reference type because `mode: .threads` shares one system under test across its lanes, which a value type cannot be.
final class SkipOnlyCounter: @unchecked Sendable, CustomDebugStringConvertible {
    private(set) var value = 0

    var debugDescription: String {
        "SkipOnlyCounter(value: \(value))"
    }
}
