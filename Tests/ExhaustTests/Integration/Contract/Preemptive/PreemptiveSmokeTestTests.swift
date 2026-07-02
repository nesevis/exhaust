import ExhaustTestSupport
import Foundation
import Testing
@testable import Exhaust

@Suite("Preemptive concurrent contract: smoke test", .serialized, .tags(.contract))
struct PreemptiveSmokeTestTests {
    @Test("Smoke test catches sequential bug before concurrent phase")
    func smokeTestCatchesSequentialBugBeforeConcurrentPhase() async {
        let result = await #execute(
            SequentiallyBrokenSpec.self,
            .concurrent(.two),
            .commandLimit(10),
            .budget(.custom(coverage: 0, sampling: 0)),
            .suppress(.issueReporting)
        )
        #expect(result?.commands.isEmpty == false)
    }

    @Test("Smoke test failure carries specific replay seed")
    func smokeTestFailureCarriesSpecificReplaySeed() async throws {
        let result = try #require(
            await #execute(
                SequentiallyBrokenSpec.self,
                .concurrent(.two),
                .commandLimit(10),
                .budget(.custom(coverage: 0, sampling: 0)),
                .suppress(.issueReporting)
            )
        )
        let replaySeed = try #require(result.replaySeed)
        #expect(replaySeed == "0-1")
    }
}

// MARK: - Spec

@Contract(.threads)
final class SequentiallyBrokenSpec {
    var expected: Int = 0
    @SystemUnderTest var counter: BrokenCounter = .init()

    @Oracle
    func valuesMatch(other: BrokenCounter) -> Bool {
        counter.value == other.value && counter.value == expected
    }

    @Command(weight: 3)
    func increment() throws {
        expected += 1
        counter.increment()
    }

    @Command(weight: 2)
    func decrement() throws {
        guard expected > 0 else {
            throw skip()
        }
        expected -= 1
        counter.decrement()
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

// MARK: - SUT

/// Broken even under sequential access — increment adds 2 instead of 1.
/// Marked `@unchecked Sendable` to satisfy `ContractSpec`; intentionally not thread-safe.
final class BrokenCounter: @unchecked Sendable, CustomDebugStringConvertible {
    private var _value: Int = 0

    var value: Int {
        _value
    }

    var debugDescription: String {
        "BrokenCounter(value: \(_value))"
    }

    func increment() {
        _value += 2
    }

    func decrement() {
        _value -= 1
    }
}
