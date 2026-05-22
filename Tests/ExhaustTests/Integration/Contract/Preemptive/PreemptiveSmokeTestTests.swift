import ExhaustTestSupport
import Foundation
import Testing
@testable import Exhaust

@Suite("Preemptive concurrent contract: smoke test", .serialized, .tags(.contract))
struct PreemptiveSmokeTestTests {
    @Test
    func `Smoke test catches sequential bug before concurrent phase`() throws {
        let result = try #require(
            __runPreemptiveConcurrentContract(
                SequentiallyBrokenSpec.self,
                settings: [
                    .concurrency(2),
                    .commandLimit(4),
                    .budget(.custom(coverage: 0, sampling: 50)),
                    .suppress(.issueReporting),
                ]
            )
        )
        #expect(result.commands.isEmpty == false)
    }
}

// MARK: - Spec

@ConcurrentContract
final class SequentiallyBrokenSpec {
    @Model var expected: Int = 0
    @SystemUnderTest var counter: BrokenCounter = .init()

    @Oracle
    func valuesMatch(other: BrokenCounter) -> Bool {
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

// MARK: - SUT

/// Broken even under sequential access — decrement is a no-op.
/// Marked `@unchecked Sendable` to satisfy `ConcurrentContractSpec`; intentionally not thread-safe.
final class BrokenCounter: @unchecked Sendable, CustomDebugStringConvertible {
    private var _value: Int = 0

    var value: Int {
        _value
    }

    var debugDescription: String {
        "BrokenCounter(value: \(_value))"
    }

    func increment() {
        _value += 1
    }

    func decrement() {
        // Bug: does nothing
    }
}
