import ExhaustTestSupport
import Testing
@testable import Exhaust

// MARK: - Tests

@Suite("Atomic counter concurrent tests", .serialized, .tags(.contract))
struct AtomicCounterConcurrentTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Thread-safe counter passes under all interleavings")
    func threadSafeCounterPassesUnderAllInterleavings() async {
        let result = await __ExhaustRuntime.__runContractConcurrent(
            AtomicCounterSpec.self,
            settings: [.commandLimit(4), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
        )
        #expect(result == nil, "Atomic counter should pass under any interleaving")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Narrow race in non-suspending counter is invisible to cooperative scheduler")
    func narrowRaceInNonSuspendingCounterIsInvisibleToCooperativeScheduler() async {
        let result = await __ExhaustRuntime.__runContractConcurrent(
            NarrowRaceCounterSpec.self,
            settings: [.commandLimit(6), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
        )
        #expect(result == nil, "NarrowRaceCounter has a real data race, but CCCR cannot interleave non-suspending methods")
    }
}

// MARK: - Specs

@Contract(.tasks)
final class AtomicCounterSpec {
    @Model
    var expected: Int = 0
    @SystemUnderTest
    var counter: ThreadSafeCounter = .init()

    @Invariant
    func matchesModel() -> Bool {
        counter.value == expected
    }

    @Command(weight: 3)
    func increment() async throws {
        expected += 1
        counter.increment()
    }

    @Command(weight: 2)
    func decrement() async throws {
        guard expected > 0 else { throw skip() }
        expected -= 1
        counter.decrement()
    }
}

@Contract(.tasks)
final class NarrowRaceCounterSpec {
    @Model
    var expected: Int = 0
    @SystemUnderTest
    var counter: NarrowRaceCounter = .init()

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
