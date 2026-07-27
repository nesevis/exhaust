import Testing
@testable import Exhaust

// Every `.tasks` lane shares one spec instance, so a command body that updates the model and then calls a suspending system under test leaves the two disagreeing while it is parked. Exhaust answers that by checking invariants only when no lane is inside a command body. These guard the three edges of that gate: the window it closes, the window it reopens when the invariant itself suspends, and the exit path a skipping lane takes when it is the last to finish.
//
// The existing "correct SUT passes" coverage (AtomicCounterSpec, NarrowRaceCounterSpec) uses systems under test with no suspension point inside, which is the one shape that cannot exhibit any of this.

@Suite("Tasks quiescence gate", .serialized, .tags(.stateMachine))
struct TasksQuiescenceGateTests {
    /// The gate's reason for existing: the textbook spec shape against a system under test whose API suspends between the model update and its own commit. Before the gate this reported a counterexample against a defect-free counter.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("A correct SUT is not reported as a counterexample when the SUT suspends mid-command")
    func correctSutPassesWhenSystemUnderTestSuspends() async {
        let result = await #execute(
            SuspendingCounterSpec.self,
            mode: .tasks,
            .commandLimit(4),
            .budget(.custom(screening: 0, sampling: 200)),
            .suppress(.all)
        )
        #expect(
            result == nil,
            """
            .tasks reported a counterexample against a defect-free SUT: \
            \(result?.commands.map(\.description) ?? [])
            """
        )
    }

    /// The gate decides whether to start an invariant check, but no lane is kept out of a command body while the check runs. An `@Invariant` that suspends therefore begins at quiescence and can resume against a moved model; the runner must detect the straddle and discard the verdict rather than report a counterexample against a correct system under test.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("A correct SUT is not reported as a counterexample when the invariant itself suspends")
    func correctSutPassesWhenInvariantSuspends() async {
        let result = await #execute(
            AsyncInvariantSuspendingCounterSpec.self,
            mode: .tasks,
            .commandLimit(4),
            .budget(.custom(screening: 0, sampling: 200)),
            .suppress(.all)
        )
        #expect(
            result == nil,
            """
            .tasks reported a counterexample against a defect-free SUT via a suspending invariant: \
            \(result?.commands.map(\.description) ?? [])
            """
        )
    }

    /// A lane that exits its command body via `skip()` may be the last to finish, holding the check another lane deferred while it was mid-body, so the skip path must reach the quiescent check or the probe ends with a completed command unverified. The schedule below constructs that ending deterministically: lane A suspends inside a body that will skip, lane B completes a command that leaves the model and the system under test permanently disagreeing (deferring its check to the busy lane A), and lane A then resumes straight into `skip()`.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("A probe whose last-finishing command skips still checks invariants at least once")
    func probeEndingInSkipStillChecksInvariants() {
        let commands: [(ScheduleMarker, LostUpdateCounterSpec.Command)] = [
            (ScheduleMarker(rawValue: 1), .skipAfterSuspending),
            (ScheduleMarker(rawValue: 2), .increment),
        ]
        let result = drainSchedule(
            taggedCommands: commands,
            setupStep: nil,
            specInit: { LostUpdateCounterSpec() },
            concurrencyLevel: 2,
            recordTrace: true
        )
        // Sanity: the schedule produced the intended shape. The skipping lane opened its body (started, then suspended) before the incrementing lane ran, and ended as a skip.
        let skipperSteps = result.trace.filter { $0.command.contains("skipAfterSuspending") }
        #expect(skipperSteps.isEmpty == false, "The skipping command should appear in the trace")
        // The increment lost its update: the model moved and the counter did not, and nothing heals that. The skipping lane is the only one positioned to run the deferred check, so it must run it on the skip path.
        #expect(
            result.passed == false,
            "A persistent model-versus-SUT divergence went unchecked because the last-finishing command skipped"
        )
    }
}

// MARK: - Specs

/// The textbook `.tasks` spec shape from the `@StateMachine` documentation, applied to a system under test whose API suspends: the model is updated, then the system under test is called.
@StateMachine
final class SuspendingCounterSpec {
    var expected: Int = 0
    @SystemUnderTest
    var counter: CommittingCounter = .init()

    @Invariant
    func matchesModel() -> Bool {
        counter.value == expected
    }

    @Command(weight: 1)
    func increment() async throws {
        expected += 1
        await counter.increment()
    }

    func failureDescription() -> String? {
        "expected: \(expected), counter: \(counter.value)"
    }
}

/// ``SuspendingCounterSpec`` with the one difference that the invariant itself suspends before comparing. The command and the counter are correct; only the check's own suspension point creates the window.
@StateMachine
final class AsyncInvariantSuspendingCounterSpec {
    var expected: Int = 0
    @SystemUnderTest
    var counter: CommittingCounter = .init()

    @Invariant
    func matchesModel() async -> Bool {
        await Task.yield()
        return counter.value == expected
    }

    @Command(weight: 1)
    func increment() async throws {
        expected += 1
        await counter.increment()
    }

    func failureDescription() -> String? {
        "expected: \(expected), counter: \(counter.value)"
    }
}

/// A spec over a counter that drops every update, so the first `increment` leaves the model and the system under test permanently disagreeing. Paired with a command that suspends and then skips, so a hand-built schedule can make the skip the probe's final exit.
@StateMachine
final class LostUpdateCounterSpec {
    var expected: Int = 0
    @SystemUnderTest
    var counter: LostUpdateCounter = .init()

    @Invariant
    func matchesModel() -> Bool {
        counter.value == expected
    }

    @Command(weight: 1)
    func increment() async throws {
        expected += 1
        counter.increment()
    }

    @Command(weight: 1)
    func skipAfterSuspending() async throws {
        // The suspension is the point: the skip decision must land after another lane has had the chance to complete a command and defer its check to this one.
        await Task.yield()
        throw skip()
    }

    func failureDescription() -> String? {
        "expected: \(expected), counter: \(counter.value)"
    }
}

// MARK: - Supporting Types

/// A counter with no defect under cooperative scheduling: the suspension precedes the read-modify-write, and the read-modify-write itself has no suspension point, so the drain loop can never interleave inside it. Every increment commits exactly once.
final class CommittingCounter: @unchecked Sendable, CustomDebugStringConvertible {
    private var storedValue: Int = 0

    var value: Int {
        storedValue
    }

    var debugDescription: String {
        "CommittingCounter(value: \(storedValue))"
    }

    func increment() async {
        await Task.yield()
        storedValue += 1
    }
}

/// A counter that acknowledges no increment: `increment()` is a lost update by construction, standing in for any system under test that drops a write.
final class LostUpdateCounter: @unchecked Sendable, CustomDebugStringConvertible {
    private var storedValue: Int = 0

    var value: Int {
        storedValue
    }

    var debugDescription: String {
        "LostUpdateCounter(value: \(storedValue))"
    }

    func increment() {
        // Deliberately drops the update.
    }
}
