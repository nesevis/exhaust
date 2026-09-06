import ExhaustCore
import Foundation
import Testing
@testable import Exhaust

#if canImport(Glibc)
    import Glibc
#endif

/// Where an async sequential spec's commands actually execute.
///
/// `trace-pc-guard` writes to a context bound to one thread — the run's own lane — and drops every edge that fires anywhere else. So a bridge that hands the spec's `async` work to the cooperative pool and puts the lane to sleep produces a run that records no coverage at all and terminates `coverageUnreachable`. Asserting on the thread is the direct test; a coverage assertion would need an instrumented system under test and would only observe the same fact indirectly.
@Suite("Async sequential bridge stays on the calling lane")
struct AsyncSequentialBridgeTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("The spec's commands run on the thread that invoked the property, not the cooperative pool")
    func commandsRunOnTheInvokingThread() async throws {
        let adapter = __ExhaustRuntime.buildAsyncSequentialSpecAdapter(ThreadRecordingSpec.self, commandLimit: 3)
        var interpreter = ValueAndChoiceTreeInterpreter(
            adapter.generator,
            materializePicks: false,
            seed: 1,
            maxRuns: UInt64.max
        )
        let candidate = try #require(try interpreter.next()).0

        // The drain loop parks the calling thread, so it has to be a GCD thread — which is where every production caller invokes it from.
        let observed = await withCheckedContinuation { (continuation: CheckedContinuation<(caller: UInt64, command: UInt64?), Never>) in
            DispatchQueue.global().async {
                ThreadRecordingSpec.observedThread.value = nil
                let caller = threadIdentifier()
                _ = adapter.property(candidate)
                continuation.resume(returning: (caller, ThreadRecordingSpec.observedThread.value))
            }
        }

        let commandThread = try #require(observed.command, "the spec ran no commands, so the assertion below would hold vacuously")
        #expect(commandThread == observed.caller)
    }
}

// MARK: - Helpers

private func threadIdentifier() -> UInt64 {
    #if canImport(Darwin)
        var identifier: UInt64 = 0
        pthread_threadid_np(nil, &identifier)
        return identifier
    #else
        return UInt64(pthread_self())
    #endif
}

@StateMachine
final class ThreadRecordingSpec {
    /// The thread the last command body ran on. A static because the spec is reconstructed per candidate.
    static let observedThread = UnsafeSendableBox<UInt64?>(nil)

    var expected: Int = 0
    @SystemUnderTest var counter: PassingCounter = .init()

    @Command
    func increment() async throws {
        ThreadRecordingSpec.observedThread.value = threadIdentifier()
        expected += 1
        counter.increment()
    }

    @Invariant
    func matches() -> Bool {
        counter.value == expected
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}
