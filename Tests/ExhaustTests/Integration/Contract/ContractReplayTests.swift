import ExhaustTestSupport
import Foundation
import Testing
@testable import Exhaust

@Suite("Contract replay seed resolution", .serialized, .tags(.contract))
struct ContractReplayTests {
    @Test("Iteration-targeted replay reproduces a sampling failure")
    func iterationTargetedReplayReproducesSamplingFailure() throws {
        let initial = try #require(
            #exhaust(
                BrokenModuloSpec.self,
                .commandLimit(6),
                .budget(.custom(coverage: 0, sampling: 200)),
                .suppress(.all)
            )
        )
        let replaySeed = try #require(initial.replaySeed)
        #expect(replaySeed.contains("-"), "Sampling replay seed should include iteration suffix")

        let replayed = try #require(
            #exhaust(
                BrokenModuloSpec.self,
                .commandLimit(6),
                .budget(.custom(coverage: 0, sampling: 200)),
                .replay(.encoded(replaySeed)),
                .suppress(.all)
            )
        )
        #expect(replayed.commands.isEmpty == false, "Replay should reproduce the failure")
    }

    @Test("Coverage row replay reproduces an SCA coverage failure")
    func coverageRowReplayReproducesSCACoverageFailure() throws {
        let initial = try #require(
            #exhaust(
                BrokenModuloSpec.self,
                .commandLimit(4),
                .suppress(.all)
            )
        )
        guard initial.discoveryMethod == .coverage else {
            // SCA was skipped or failure came from sampling — not testable for coverage replay
            return
        }
        let replaySeed = try #require(initial.replaySeed)
        #expect(replaySeed.hasPrefix("U"), "SCA replay seed should have U prefix")

        let replayed = try #require(
            #exhaust(
                BrokenModuloSpec.self,
                .commandLimit(4),
                .replay(.encoded(replaySeed)),
                .suppress(.all)
            )
        )
        #expect(replayed.commands.isEmpty == false, "Coverage row replay should reproduce the failure")
    }

    @Test("Seed-only replay (no iteration) still finds failure within budget")
    func seedOnlyReplayFindsFailureWithinBudget() throws {
        let initial = try #require(
            #exhaust(
                BrokenModuloSpec.self,
                .commandLimit(6),
                .budget(.custom(coverage: 0, sampling: 200)),
                .suppress(.all)
            )
        )
        let seed = try #require(initial.seed)

        let replayed = try #require(
            #exhaust(
                BrokenModuloSpec.self,
                .commandLimit(6),
                .budget(.custom(coverage: 0, sampling: 200)),
                .replay(.numeric(seed)),
                .suppress(.all)
            )
        )
        #expect(replayed.commands.isEmpty == false)
    }
}

@Suite("Concurrent contract replay seed resolution", .serialized, .tags(.contract))
struct ConcurrentContractReplayTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Iteration-targeted replay reproduces a cooperative concurrent failure")
    func iterationTargetedReplayReproducesCooperativeConcurrentFailure() async throws {
        let initial = try #require(
            await __ExhaustRuntime.__runContractConcurrent(
                ReplayableNonAtomicCounterSpec.self,
                settings: [
                    .commandLimit(6),
                    .budget(.custom(coverage: 0, sampling: 2000)),
                    .suppress(.all),
                ]
            )
        )
        let replaySeed = try #require(initial.replaySeed)
        #expect(replaySeed.contains("-"), "Sampling replay seed should include iteration suffix")

        let replayed = try #require(
            await __ExhaustRuntime.__runContractConcurrent(
                ReplayableNonAtomicCounterSpec.self,
                settings: [
                    .commandLimit(6),
                    .budget(.custom(coverage: 0, sampling: 2000)),
                    .replay(.encoded(replaySeed)),
                    .suppress(.all),
                ]
            )
        )
        #expect(replayed.commands.isEmpty == false, "Iteration-targeted replay should reproduce the failure")
        #expect(replayed.discoveryMethod == .replay)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Coverage row replay reproduces a cooperative concurrent SCA failure")
    func coverageRowReplayReproducesCooperativeConcurrentSCAFailure() async throws {
        let initial = try #require(
            await __ExhaustRuntime.__runContractConcurrent(
                ReplayableNonAtomicCounterSpec.self,
                settings: [
                    .commandLimit(6),
                    .budget(.custom(coverage: 2000, sampling: 0)),
                    .suppress(.all),
                ]
            )
        )
        let replaySeed = try #require(initial.replaySeed)
        #expect(replaySeed.hasPrefix("U"), "Coverage replay seed should have U prefix")

        let replayed = try #require(
            await __ExhaustRuntime.__runContractConcurrent(
                ReplayableNonAtomicCounterSpec.self,
                settings: [
                    .commandLimit(6),
                    .budget(.custom(coverage: 2000, sampling: 0)),
                    .replay(.encoded(replaySeed)),
                    .suppress(.all),
                ]
            )
        )
        #expect(replayed.commands.isEmpty == false, "Coverage row replay should reproduce the failure")
    }
}

// MARK: - Sequential Spec

@Contract
struct BrokenModuloSpec {
    @Model var expected: Int = 0
    @SystemUnderTest var counter = ModuloCounter(modulus: 3)

    @Invariant
    func valueMatches() -> Bool {
        counter.value == expected
    }

    @Command(weight: 3)
    mutating func increment() throws {
        expected = (expected + 1) % 5
        counter.increment()
    }

    @Command(weight: 1)
    mutating func reset() throws {
        expected = 0
        counter.reset()
    }
}

struct ModuloCounter {
    private(set) var value: Int = 0
    let modulus: Int

    mutating func increment() {
        value = (value + 1) % modulus
    }

    mutating func reset() {
        value = 0
    }
}

// MARK: - Cooperative Concurrent Spec

@Contract
final class ReplayableNonAtomicCounterSpec {
    @Model var expected: Int = 0
    @SystemUnderTest var counter: ReplayableNonAtomicCounter = .init()

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

actor ReplayableNonAtomicCounter: CustomDebugStringConvertible {
    private var _value: Int = 0

    nonisolated var value: Int {
        // Intentionally non-isolated read for race detection
        withUnsafePointer(to: self) { pointer in
            pointer.withMemoryRebound(to: Int.self, capacity: 2) { $0[1] }
        }
    }

    nonisolated var debugDescription: String {
        "ReplayableNonAtomicCounter(value: \(value))"
    }

    func increment() {
        _value += 1
    }

    func decrement() {
        _value -= 1
    }
}

// MARK: - Preemptive Concurrent Spec

@ConcurrentContract
final class PreemptiveReplayableSpec {
    @Model var expected: Int = 0
    @SystemUnderTest var counter: PreemptiveRacyCounter = .init()

    @Oracle
    func oracleMatches(other: PreemptiveRacyCounter) -> Bool {
        counter.value == other.value
    }

    @Invariant
    func matchesModel() -> Bool {
        counter.value == expected
    }

    @Command(weight: 3)
    func increment() throws {
        expected += 1
        counter.increment()
    }

    @Command(weight: 2)
    func decrement() throws {
        guard expected > 0 else { throw skip() }
        expected -= 1
        counter.decrement()
    }
}

/// Non-thread-safe counter for preemptive race detection.
final class PreemptiveRacyCounter: @unchecked Sendable, CustomDebugStringConvertible {
    private var _value: Int = 0

    var value: Int {
        _value
    }

    var debugDescription: String {
        "PreemptiveRacyCounter(value: \(_value))"
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

// MARK: - Preemptive Sequentially Broken Spec

@ConcurrentContract
final class PreemptiveSequentiallyBrokenSpec {
    @Model var expected: Int = 0
    @SystemUnderTest var counter: BrokenDecrementCounter = .init()

    @Oracle
    func oracleMatches(other: BrokenDecrementCounter) -> Bool {
        counter.value == other.value
    }

    @Invariant
    func matchesModel() -> Bool {
        counter.value == expected
    }

    @Command(weight: 3)
    func increment() throws {
        expected += 1
        counter.increment()
    }

    @Command(weight: 2)
    func decrement() throws {
        guard expected > 0 else { throw skip() }
        expected -= 1
        counter.decrement()
    }
}

final class BrokenDecrementCounter: @unchecked Sendable, CustomDebugStringConvertible {
    private var _value: Int = 0

    var value: Int {
        _value
    }

    var debugDescription: String {
        "BrokenDecrementCounter(value: \(_value))"
    }

    func increment() {
        _value += 1
    }

    func decrement() {
        // Bug: no-op
    }
}
