import Testing
@testable import Exhaust

// MARK: - Tests

@Suite("Atomic counter concurrent tests")
struct AtomicCounterConcurrentTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Thread-safe counter passes under all interleavings")
    func atomicCounterPasses() async {
        let result = await __runContractConcurrent(
            AtomicCounterSpec.self,
            settings: [.commandLimit(4), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
        )
        #expect(result == nil, "Atomic counter should pass under any interleaving")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("No interleaving possible when SUT has no internal suspension points")
    func noSuspensionNoInterleaving() async {
        let result = await __runContractConcurrent(
            AtomicCounterSpec.self,
            settings: [.commandLimit(6), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
        )
        #expect(result == nil, "Atomic counter has no suspension points — no interleaving can occur, so no bug is found")
    }
}

// MARK: - Spec

@Contract
final class AtomicCounterSpec {
    @Model
    var expected: Int = 0
    @SystemUnderTest
    var counter: AtomicCounter = .init()

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

/// Deliberately unsynchronized — @unchecked Sendable is required because the cooperative scheduler accesses the instance from multiple Tasks via SendableBox.
final class AtomicCounter: @unchecked Sendable {
    private var _value: Int = 0

    var value: Int {
        _value
    }

    func increment() async {
        _value += 1
    }

    func decrement() async {
        _value -= 1
    }
}
