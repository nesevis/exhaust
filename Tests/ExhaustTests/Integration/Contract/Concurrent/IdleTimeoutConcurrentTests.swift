import ExhaustTestSupport
import Testing
@testable import Exhaust

// MARK: - Tests

@Suite("Idle timeout concurrent tests", .serialized, .tags(.contract))
struct IdleTimeoutConcurrentTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Idle timeout fires for SUT that escapes the cooperative executor")
    func idleTimeoutFiresForSUTThatEscapesTheCooperativeExecutor() async throws {
        let result = try #require(
            await __ExhaustRuntime.__runContractConcurrent(
                SleepingSpec.self,
                settings: [.commandLimit(2), .idleTimeoutMs(10), .budget(.custom(coverage: 0, sampling: 10)), .suppress(.issueReporting)]
            )
        )
        #expect(result.discoveryMethod == .randomSampling)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("blockingAwait bails with nil when the awaited work never returns to the drain lane")
    func blockingAwaitBailsWhenWorkSuspendsOffTheDrainLane() async {
        // The work suspends far longer than the idle bound and its continuation does not feed the single drain lane, so without the bound the loop would spin a core forever. `blockingAwait` must return nil instead. The test completing (rather than hanging) is itself the regression guard.
        let result: Bool? = await __ExhaustRuntime.dispatchToGCD {
            __ExhaustRuntime.blockingAwait(idleTimeoutMilliseconds: 20) {
                try? await Task.sleep(for: .milliseconds(500))
                return true
            }
        }
        #expect(result == nil)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Async preemptive idle timeout surfaces a stalling command as a timeout, not a race")
    func asyncPreemptiveIdleTimeoutSurfacesStallingCommand() async throws {
        var deliveredReport: ExhaustReport?
        let result = try #require(
            await __ExhaustRuntime.__runPreemptiveConcurrentContractAsync(
                StallingAsyncSpec.self,
                settings: [
                    .concurrent(2),
                    .commandLimit(2),
                    .idleTimeoutMs(20),
                    .budget(.custom(coverage: 0, sampling: 10)),
                    .suppress(.issueReporting),
                    .onReport { deliveredReport = $0 },
                ]
            )
        )
        #expect(result.commands.isEmpty == false)

        // The stalling command always exceeds the idle bound, so the first sampling run times out. The runner must route that to the timeout path: flag the failure (so it renders as a timeout rather than a confirmed race) and skip reduction (slow and usually fruitless on a hang). Zero reduction probes is the regression signal — a failure misclassified as a race would have run the three-pass reducer, leaving `reductionInvocations > 0`.
        let report = try #require(deliveredReport)
        #expect(report.reductionInvocations == 0)
        #expect(report.randomSamplingInvocations == 1)
        #expect(report.propertyInvocations == 1)
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

// MARK: - Async Preemptive Spec

/// A command that sleeps far longer than the idle bound — its drain lane goes quiet, so the preemptive runner's idle timeout must fire and surface it rather than hang. The oracle always agrees; the failure comes purely from the timeout.
@ConcurrentContract
final class StallingAsyncSpec {
    @SystemUnderTest
    var counter: SleepingAsyncCounter = .init()

    @Oracle
    func valuesMatch(other _: SleepingAsyncCounter) -> Bool {
        true
    }

    @Command(weight: 1)
    func doSleep() async throws {
        await counter.sleepAndIncrement()
    }
}

final class SleepingAsyncCounter: @unchecked Sendable {
    private var _value: Int = 0

    func sleepAndIncrement() async {
        try? await Task.sleep(for: .milliseconds(200))
        _value += 1
    }
}
