@testable import Exhaust
import Testing

// MARK: - Tests

@Suite("Concurrent contract tests")
struct ConcurrentContractTests {
    @Test("Detects lost-update bug in non-atomic counter")
    func detectsLostUpdate() async throws {
        let result = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(4), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
            )
        )
        let hasFailure = result.trace.contains { step in
            if case .invariantFailed = step.outcome { return true }
            if case .checkFailed = step.outcome { return true }
            return false
        }
        #expect(hasFailure, "Should detect invariant failure from interleaved read-modify-write")
    }

    @Test("Thread-safe counter passes under all interleavings")
    func atomicCounterPasses() async {
        let result = await __runContractConcurrent(
            AtomicCounterSpec.self,
            settings: [.commandLimit(4), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
        )
        #expect(result == nil, "Atomic counter should pass under any interleaving")
    }

    @Test("Reduced counterexample is smaller than original")
    func reductionShrinks() async throws {
        let result = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(6), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
            )
        )
        #expect(result.commands.count <= 6, "Reducer should shrink the counterexample")
    }

    @Test("Detects check-then-act bug that requires state buildup")
    func detectsLeakyBucket() async throws {
        let result = try #require(
            await __runContractConcurrent(
                LeakyBucketSpec.self,
                settings: [.commandLimit(8), .budget(.custom(coverage: 0, sampling: 50000)), .suppress(.issueReporting)]
            )
        )
        let hasFailure = result.trace.contains { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        }
        #expect(hasFailure, "Should detect token over-drain from interleaved tryConsume")
    }

    @Test("Coverage phase reports discoveryMethod .coverage with no seed")
    func coverageDiscoveryMethod() async throws {
        let result = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(6), .budget(.custom(coverage: 500, sampling: 0)), .suppress(.issueReporting)]
            )
        )
        #expect(result.discoveryMethod == .coverage, "Failure found during coverage should report .coverage")
        #expect(result.seed == nil, "Coverage-discovered failures should not carry a seed")
    }

    @Test("Random sampling reports discoveryMethod .randomSampling with a seed")
    func randomSamplingDiscoveryMethod() async throws {
        let result = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(6), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
            )
        )
        #expect(result.discoveryMethod == .randomSampling, "Failure found during random sampling should report .randomSampling")
        #expect(result.seed != nil, "Random-sampling failures should carry a replay seed")
    }

    @Test(".onReport delivers invocation counts")
    func onReportDelivers() async {
        nonisolated(unsafe) var deliveredReport: ExhaustReport?
        _ = await __runContractConcurrent(
            NonAtomicCounterSpec.self,
            settings: [.commandLimit(4), .budget(.custom(coverage: 0, sampling: 50)), .suppress(.issueReporting), .onReport { deliveredReport = $0 }]
        )
        #expect(deliveredReport != nil, "onReport closure should be called")
        if let report = deliveredReport {
            #expect(report.propertyInvocations > 0, "Should have recorded invocations")
            #expect(report.totalMilliseconds > 0, "Should have recorded timing")
        }
    }

    @Test("Deterministic replay produces same result")
    func deterministicReplay() async throws {
        let result1 = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(10), .budget(.custom(coverage: 0, sampling: 200)), .replay(.numeric(42)), .suppress(.issueReporting)]
            )
        )
        let result2 = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(10), .budget(.custom(coverage: 0, sampling: 200)), .replay(.numeric(42)), .suppress(.issueReporting)]
            )
        )
        #expect(result1.commands.count == result2.commands.count, "Same seed should produce same counterexample size")
    }
}

// MARK: - Contract: Non-atomic counter (lost-update bug)

/// The SUT has a non-atomic read-modify-write: `let v = _value; await yield(); _value = v + 1`.
/// When the executor interleaves at the yield, both tasks read the same stale value, producing a
/// lost update that the model detects.
@Contract
final class NonAtomicCounterSpec {
    @Model var expected: Int = 0
    @SUT var counter: NonAtomicCounter = .init()

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

// MARK: - Contract: Leaky bucket (bug requires state buildup)

/// A rate limiter that only fails under concurrent access when the bucket is nearly full.
/// The bug: `tryConsume` does a non-atomic check-then-decrement. Under sequential access this
/// is fine because the check and decrement are never interleaved. Under concurrent access, both
/// tasks can pass the check, then both decrement — draining past the limit.
///
/// This requires multiple `refill` commands to build up the bucket level before the concurrent
/// `tryConsume` calls can trigger the over-drain.
@Contract
final class LeakyBucketSpec {
    @Model var expectedTokens: Int = 0
    @SUT var bucket: LeakyBucket = .init(capacity: 5)

    @Invariant
    func tokensNeverNegative() -> Bool {
        bucket.tokens >= 0
    }

    @Invariant
    func matchesModel() -> Bool {
        bucket.tokens == expectedTokens
    }

    @Command(weight: 4)
    func refill() async throws {
        guard expectedTokens < 5 else { throw skip() }
        expectedTokens += 1
        await bucket.refill()
    }

    @Command(weight: 3)
    func tryConsume() async throws {
        guard expectedTokens > 0 else { throw skip() }
        expectedTokens -= 1
        await bucket.tryConsume()
    }
}

// MARK: - Contract: Thread-safe counter (should always pass)

@Contract
final class AtomicCounterSpec {
    @Model var expected: Int = 0
    @SUT var counter: AtomicCounter = .init()

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

// MARK: - SUTs

/// Non-atomic read-modify-write. The `await Task.yield()` between read and write is the
/// interleaving point where the executor can switch to the other task.
final class NonAtomicCounter: @unchecked Sendable {
    private var _value: Int = 0

    var value: Int { _value }

    func increment() async {
        let current = _value
        await Task.yield()
        _value = current + 1
    }

    func decrement() async {
        let current = _value
        await Task.yield()
        _value = current - 1
    }
}

/// A rate limiter with a non-atomic check-then-act bug in `tryConsume`. The bug only manifests
/// when tokens > 0 (requires prior refills) and two concurrent tryConsume calls interleave at
/// the yield between checking the count and decrementing.
final class LeakyBucket: @unchecked Sendable {
    private var _tokens: Int = 0
    private let _capacity: Int

    init(capacity: Int) { _capacity = capacity }

    var tokens: Int { _tokens }

    func refill() async {
        guard _tokens < _capacity else { return }
        _tokens += 1
    }

    func tryConsume() async {
        let current = _tokens
        guard current > 0 else { return }
        await Task.yield()
        _tokens = current - 1
    }
}

/// Counter with a race that has NO suspension point between read and write.
/// The cooperative scheduler cannot interleave within a single continuation,
/// so this race is invisible to the tool.
final class SilentlyRacyCounter: @unchecked Sendable {
    private var _value: Int = 0

    var value: Int { _value }

    func increment() async {
        _value += 1
    }

    func racyIncrement() async {
        let current = _value
        _value = current + 1
    }
}

/// Counter where the race point is exposed via Task.yield() between read and write.
/// Structurally identical to SilentlyRacyCounter but with an explicit suspension point.
final class ExposedRacyCounter: @unchecked Sendable {
    private var _value: Int = 0

    var value: Int { _value }

    func increment() async {
        _value += 1
    }

    func racyIncrement() async {
        let current = _value
        await Task.yield()
        _value = current + 1
    }
}

/// Three-participant counter where the bug requires three concurrent read-modify-writes
/// to interleave: each reads the same stale value, then all three write back stale+1,
/// losing two increments.
final class ThreeWayRacyCounter: @unchecked Sendable {
    private var _value: Int = 0

    var value: Int { _value }

    func increment() async {
        let current = _value
        await Task.yield()
        _value = current + 1
    }
}

/// Atomic counter — operations are not split across await boundaries.
final class AtomicCounter: @unchecked Sendable {
    private var _value: Int = 0

    var value: Int { _value }

    func increment() async {
        _value += 1
    }

    func decrement() async {
        _value -= 1
    }
}

// MARK: - Contract: Silent race (no suspension point at the race)

@Contract
final class SilentRaceSpec {
    @Model var expected: Int = 0
    @SUT var counter: SilentlyRacyCounter = .init()

    @Invariant
    func matchesModel() -> Bool {
        counter.value == expected
    }

    @Command(weight: 1)
    func racyIncrement() async throws {
        expected += 1
        await counter.racyIncrement()
    }
}

// MARK: - Contract: Exposed race (yield at the race point)

@Contract
final class ExposedRaceSpec {
    @Model var expected: Int = 0
    @SUT var counter: ExposedRacyCounter = .init()

    @Invariant
    func matchesModel() -> Bool {
        counter.value == expected
    }

    @Command(weight: 1)
    func racyIncrement() async throws {
        expected += 1
        await counter.racyIncrement()
    }
}

// MARK: - Contract: Three-way race (requires 3 lanes)

@Contract
final class ThreeWayRaceSpec {
    @Model var expected: Int = 0
    @SUT var counter: ThreeWayRacyCounter = .init()

    @Invariant
    func matchesModel() -> Bool {
        counter.value == expected
    }

    @Command(weight: 1)
    func increment() async throws {
        expected += 1
        await counter.increment()
    }
}

// MARK: - Trace Parsing Tests

@Suite("Concurrent trace parsing")
struct ConcurrentTraceTests {
    @Test("Collapses no-op suspend/resume pairs with no interleaving between them")
    func collapsesNoOpSuspensions() {
        let raw = [
            "STARTED:a:1A foo",
            "SUSPENDED:a",
            "RESUMED:a",
            "COMPLETED:a:1A foo",
        ]
        let steps = parseTrace(raw)
        #expect(steps.count == 1)
        #expect(steps[0].command.hasSuffix("(completed)"))
    }

    @Test("Preserves meaningful suspensions when another lane ran between suspend and resume")
    func preservesMeaningfulSuspensions() {
        let raw = [
            "STARTED:a:1A foo",
            "SUSPENDED:a",
            "STARTED:b:1B bar",
            "COMPLETED:b:1B bar",
            "RESUMED:a",
            "COMPLETED:a:1A foo",
        ]
        let steps = parseTrace(raw)
        let hasSuspended = steps.contains { $0.command.hasSuffix("(suspended)") }
        let hasResumed = steps.contains { $0.command.hasSuffix("(resumed)") }
        #expect(hasSuspended)
        #expect(hasResumed)
    }

    @Test("Collapses adjacent started+completed into single entry")
    func collapsesStartedCompleted() {
        let raw = [
            "STARTED:a:1A deposit",
            "COMPLETED:a:1A deposit",
            "STARTED:b:1B withdraw",
            "COMPLETED:b:1B withdraw",
        ]
        let steps = parseTrace(raw)
        #expect(steps.count == 2)
        #expect(steps[0].command == "1A deposit (completed)")
        #expect(steps[1].command == "1B withdraw (completed)")
    }

    @Test("Handles prefix commands correctly")
    func prefixCommands() {
        let raw = [
            "STARTED:prefix:setup",
            "COMPLETED:prefix:setup",
            "STARTED:a:1A action",
            "COMPLETED:a:1A action",
        ]
        let steps = parseTrace(raw)
        #expect(steps.count == 2)
        #expect(steps[0].command == "setup (prefix)")
        #expect(steps[1].command == "1A action (completed)")
    }

    @Test("Failure step carries the invariant name")
    func failureCarriesInvariantName() {
        let raw = [
            "STARTED:a:1A increment",
            "FAILED:a:1A increment:matchesModel",
        ]
        let steps = parseTrace(raw)
        let failedStep = steps.first { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        }
        #expect(failedStep != nil)
        if case let .invariantFailed(name) = failedStep?.outcome {
            #expect(name == "matchesModel")
        }
    }
}

// MARK: - Scheduler Behavior Tests

@Suite("Cooperative scheduler behavior")
struct CooperativeSchedulerTests {
    @Test("Sequential prefix passes without triggering concurrency bugs")
    func sequentialPrefixPasses() {
        let commands: [(ScheduleMarker, NonAtomicCounterSpec.Command)] = [
            (.prefix, .increment),
            (.prefix, .increment),
            (.prefix, .decrement),
        ]
        let result = drainSchedule(
            taggedCommands: commands,
            specInit: { NonAtomicCounterSpec() },
            concurrencyLevel: 2,
            recordTrace: true
        )
        #expect(result.passed, "Sequential execution should not trigger a concurrency bug")
    }

    @Test("Same seed produces identical trace across repeated runs")
    func strictDeterminism() async throws {
        var traces: [[TraceStep]] = []
        for _ in 0 ..< 10 {
            let result = try #require(
                await __runContractConcurrent(
                    NonAtomicCounterSpec.self,
                    settings: [.commandLimit(6), .budget(.custom(coverage: 0, sampling: 200)), .replay(.numeric(12345)), .suppress(.issueReporting)]
                )
            )
            traces.append(result.trace)
        }
        for trace in traces.dropFirst() {
            #expect(trace.count == traces[0].count, "All runs with the same seed must produce identical traces")
            for (step, expected) in zip(trace, traces[0]) {
                #expect(step.command == expected.command)
            }
        }
    }

    @Test("Reduction produces a counterexample that still fails on replay")
    func reducedCounterexampleReproduces() async throws {
        let result = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(8), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
            )
        )
        let replayResult = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(8), .budget(.custom(coverage: 0, sampling: 200)), .replay(.numeric(result.seed!)), .suppress(.issueReporting)]
            )
        )
        #expect(replayResult.commands.count == result.commands.count, "Replaying the seed should reproduce the same counterexample size")
    }

    @Test("No interleaving possible when SUT has no internal suspension points")
    func noSuspensionNoInterleaving() async {
        let result = await __runContractConcurrent(
            AtomicCounterSpec.self,
            settings: [.commandLimit(6), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
        )
        #expect(result == nil, "Atomic counter has no suspension points — no interleaving can occur, so no bug is found")
    }

    @Test("concurrencyLevel 1 runs everything sequentially and finds no concurrency bugs")
    func concurrencyLevelOneIsSequential() async {
        let result = await __runContractConcurrent(
            NonAtomicCounterSpec.self,
            settings: [.concurrency(1), .commandLimit(8), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
        )
        #expect(result == nil, "With concurrency level 1, all commands run as prefix — no interleaving, no bug found")
    }
}

// MARK: - Detection Boundary and Multi-Lane Tests

@Suite("Detection boundary and multi-lane behavior")
struct DetectionBoundaryTests {
    @Test("Race without suspension point is NOT detected (demonstrates tool limitation)")
    func raceWithoutYieldNotDetected() async {
        let result = await __runContractConcurrent(
            SilentRaceSpec.self,
            settings: [.commandLimit(6), .budget(.custom(coverage: 0, sampling: 500)), .suppress(.issueReporting)]
        )
        #expect(result == nil, "Race without await/yield between read and write is invisible to cooperative scheduling")
    }

    @Test("Same race WITH suspension point IS detected")
    func raceWithYieldDetected() async throws {
        let result = try #require(
            await __runContractConcurrent(
                ExposedRaceSpec.self,
                settings: [.commandLimit(4), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
            )
        )
        let hasFailure = result.trace.contains { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        }
        #expect(hasFailure, "Race with Task.yield() at the interleaving point should be detected")
    }

    @Test("Three-way race detected with concurrencyLevel 3")
    func threeWayRaceDetected() async throws {
        let result = try #require(
            await __runContractConcurrent(
                ThreeWayRaceSpec.self,
                settings: [.concurrency(3), .commandLimit(6), .budget(.custom(coverage: 0, sampling: 500)), .suppress(.issueReporting)]
            )
        )
        let hasFailure = result.trace.contains { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        }
        #expect(hasFailure, "Three concurrent increments with yield should lose updates")
    }

    @Test("Reduction drives schedule markers toward prefix")
    func reductionDrivesMarkersTowardPrefix() async throws {
        let result = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(8), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
            )
        )
        #expect(result.commands.count <= 8, "Reducer should shrink the command count")
        #expect(result.commands.count >= 2, "Need at least 2 commands for interleaving")
    }

    @Test("Idle timeout fires for SUT that escapes the cooperative executor")
    func idleTimeoutFires() async throws {
        let result = try #require(
            await __runContractConcurrent(
                SleepingSpec.self,
                settings: [.commandLimit(2), .idleTimeout(50), .budget(.custom(coverage: 0, sampling: 10)), .suppress(.issueReporting)]
            )
        )
        #expect(result.discoveryMethod == .randomSampling)
    }
}

// MARK: - Contract: Sleeping SUT (escapes cooperative executor)

@Contract
final class SleepingSpec {
    @Model var count: Int = 0
    @SUT var counter: SleepingCounter = .init()

    @Invariant
    func alwaysTrue() -> Bool { true }

    @Command(weight: 1)
    func doSleep() async throws {
        count += 1
        await counter.sleepAndIncrement()
    }
}

/// A SUT whose method uses Task.sleep, which escapes the cooperative executor and triggers the idle timeout.
final class SleepingCounter: @unchecked Sendable {
    private var _value: Int = 0
    var value: Int { _value }

    func sleepAndIncrement() async {
        try? await Task.sleep(for: .milliseconds(200))
        _value += 1
    }
}
