import ExhaustCore
import ExhaustTestSupport
import Foundation
import IssueReporting
import Testing
@testable import Exhaust

// MARK: - Tests

@Suite("Idle timeout concurrent tests", .serialized, .tags(.contract))
struct IdleTimeoutConcurrentTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Always-stalling cooperative SUT passes under the idle timeout and warns")
    func idleTimeoutForSUTThatEscapesTheCooperativeExecutorPassesWithWarning() async {
        // Every probe of SleepingSpec sleeps past the 10ms idle bound, so every probe times out. A timed-out probe counts as a pass — so the run finds no counterexample and returns nil rather than reporting a `.timeout` failure that contention could also produce. Because timeouts consume the whole budget, the runner emits a warning instead of passing silently.
        let reporter = CapturingIssueReporter()
        let result = await withIssueReporters([reporter]) {
            await #execute(
                SleepingSpec.self,
                .commandLimit(2),
                .idleTimeoutMs(10),
                .budget(.custom(coverage: 0, sampling: 10))
            )
        }
        #expect(result == nil)
        #expect(reporter.warnings.count == 1)
        #expect(reporter.errors.isEmpty)
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
    @Test("Async preemptive idle timeout makes a stalling command pass and warns, without reducing")
    func asyncPreemptiveIdleTimeoutSurfacesStallingCommand() async throws {
        // The stalling command always exceeds the idle bound, so every probe times out. A timed-out probe counts as a pass, so discovery runs the full sampling budget, finds no counterexample, and returns nil. No candidate means no reduction: `reductionInvocations == 0` is the regression signal — a timeout misclassified as a race would have run the three-pass reducer, leaving `reductionInvocations > 0`. Because timeouts consume the whole budget, a warning fires.
        let reportBox = UnsafeSendableBox<ExhaustReport?>(nil)
        let reporter = CapturingIssueReporter()
        let result = await withIssueReporters([reporter]) {
            await #execute(
                StallingAsyncSpec.self,
                .concurrent(.two),
                .commandLimit(2),
                .idleTimeoutMs(20),
                .budget(.custom(coverage: 0, sampling: 10)),
                .onReport { report in reportBox.value = report }
            )
        }
        #expect(result == nil)
        #expect(reporter.warnings.count == 1)

        let report = try #require(reportBox.value)
        #expect(report.reductionInvocations == 0)
        #expect(report.coverageInvocations == 0)
        // One smoke probe plus the full 10-probe sampling budget, all timing out as passes; the sampling loop never short-circuits. The smoke and sampling phases share the `randomSamplingInvocations` bucket.
        #expect(report.randomSamplingInvocations == 11)
    }

    @Test("Async preemptive group.wait bound prevents hang on synchronous SUT deadlock")
    func asyncPreemptiveGroupWaitBoundPreventsHangOnSynchronousSUTDeadlock() async {
        _ = await #execute(
            DeadlockingAsyncSpec.self,
            .concurrent(.two),
            .commandLimit(2),
            .idleTimeoutMs(50),
            .budget(.custom(coverage: 0, sampling: 50)),
            .suppress(.all)
        )
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Cooperative reduction timeout aborts reduction without flipping the failure to a timeout")
    func cooperativeReductionTimeoutKeepsFailure() throws {
        // Every probe of SleepingSpec stalls past the idle bound, so reduction times out on its first probe.
        let commandGen = SleepingSpec.commandGenerator.gen
        let taggedGen = try #require(__ExhaustRuntime.zipScheduleMarker(onto: commandGen, concurrencyLevel: 2))
        let sequenceGen = Gen.arrayOf(taggedGen, within: 2 ... 2, scaling: .constant)
        var interpreter = ValueAndChoiceTreeInterpreter(sequenceGen, seed: 0, maxRuns: 1)
        let (commands, tree) = try #require(try interpreter.next())

        var config = ResolvedConcurrentConfig()
        config.budget = .custom(coverage: 0, sampling: 10)
        config.suppressIssueReporting = true

        let lastRunTimedOut = UnsafeSendableBox(false)
        let context = ContractRunContext<SleepingSpec>(
            config: config,
            sequenceGen: sequenceGen,
            commandGen: commandGen,
            commandLimit: 2,
            identifySkips: { _ in [] },
            lastRunTimedOut: lastRunTimedOut,
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column
        )
        let backend = CooperativeContractBackend<SleepingSpec>(
            specInit: { SleepingSpec() },
            concurrencyLevel: 2,
            idleTimeoutMilliseconds: 10
        )

        let reduction = backend.reduce(taggedCommands: commands, tree: tree, context: context)

        // The probe timed out during reduction (so the scenario is exercised), but that must not latch the shared timeout flag that `buildResult` reads to set the status — a genuine failure stays `.fail`, not `.timeout`.
        #expect(reduction.timedOut)
        #expect(context.lastRunTimedOut == false)
    }

    @Test("Timeout-fraction warning fires at the budget fraction and is silent below it")
    func timeoutFractionWarningThreshold() {
        // 0.25 of the budget is the threshold: 25/100 reaches it, 24/100 does not.
        let firing = CapturingIssueReporter()
        withIssueReporters([firing]) {
            warnIfTimeoutFractionHigh(
                timedOutProbes: 25,
                totalBudget: 100,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
        }
        #expect(firing.warnings.count == 1)

        let silent = CapturingIssueReporter()
        withIssueReporters([silent]) {
            warnIfTimeoutFractionHigh(
                timedOutProbes: 24,
                totalBudget: 100,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
        }
        #expect(silent.warnings.isEmpty)
    }
}

// MARK: - Spec

@Contract(.tasks)
final class SleepingSpec {
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

    func failureDescription() -> String? {
        "\(counter)"
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
@Contract(.threads)
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

    func failureDescription() -> String? {
        "\(counter)"
    }
}

final class SleepingAsyncCounter: @unchecked Sendable {
    private var _value: Int = 0

    func sleepAndIncrement() async {
        try? await Task.sleep(for: .milliseconds(200))
        _value += 1
    }
}

// MARK: - Deadlocking Async Spec

@Contract(.threads)
final class DeadlockingAsyncSpec {
    @SystemUnderTest
    var sut: DeadlockingSUT = .init()

    @Oracle
    func valuesMatch(other _: DeadlockingSUT) -> Bool {
        true
    }

    @Command(weight: 1)
    func lockAB() async throws {
        sut.acquireAB()
    }

    @Command(weight: 1)
    func lockBA() async throws {
        sut.acquireBA()
    }

    func failureDescription() -> String? {
        "\(sut)"
    }
}

final class DeadlockingSUT: @unchecked Sendable, CustomDebugStringConvertible {
    private let lockA = NSLock()
    private let lockB = NSLock()

    var debugDescription: String {
        "DeadlockingSUT"
    }

    func acquireAB() {
        lockA.lock()
        Thread.sleep(forTimeInterval: 0.001)
        lockB.lock()
        lockB.unlock()
        lockA.unlock()
    }

    func acquireBA() {
        lockB.lock()
        Thread.sleep(forTimeInterval: 0.001)
        lockA.lock()
        lockA.unlock()
        lockB.unlock()
    }
}

// MARK: - Test Support

/// An ``IssueReporter`` that records reported issues by severity so a test can assert which warnings (or errors) the runner emitted, instead of letting them reach the test framework.
private final class CapturingIssueReporter: IssueReporter, @unchecked Sendable {
    private let lock = NSLock()
    private var warningMessages: [String] = []
    private var errorMessages: [String] = []

    var warnings: [String] {
        lock.withLock { warningMessages }
    }

    var errors: [String] {
        lock.withLock { errorMessages }
    }

    func reportIssue(
        _ message: @autoclosure () -> String?,
        severity: IssueSeverity,
        fileID _: StaticString,
        filePath _: StaticString,
        line _: UInt,
        column _: UInt
    ) {
        let captured = message() ?? ""
        lock.withLock {
            switch severity {
                case .warning: warningMessages.append(captured)
                case .error: errorMessages.append(captured)
            }
        }
    }
}
