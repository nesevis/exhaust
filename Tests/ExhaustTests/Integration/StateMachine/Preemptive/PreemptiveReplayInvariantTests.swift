import ExhaustCore
import Foundation
import Testing
@testable import Exhaust

// A thread-based probe runs every lane's commands on one shared spec instance, and it judges invariants only where a single command runs at a time: the per-probe sequential reference replay, and the replays inside the interleaving search (ADR 0004). These drive one probe directly, because a pipeline run reduces, repeats, and reports, and never shows which verdict a single probe reached.

@Suite("Preemptive replay invariants", .serialized, .tags(.stateMachine))
struct PreemptiveReplayInvariantTests {
    /// The sharing ADR 0004 restored, and the test that fails if anyone splits the spec per lane again.
    ///
    /// The model is deliberately thread-safe, which is the shape per-lane instances silently broke: the spec is written on the promise that its commands run concurrently against *it*, so every lane's write has to land in the one model it declares. The equivalence states that promise as a claim — the model and the system under test hold the same total — and only a shared instance satisfies it. Split instances would leave the concurrent instance's model holding the prefix alone while its system under test held every lane's write.
    @Test("Every lane's commands run on one shared spec instance")
    func everyLanesCommandsRunOnOneSharedSpecInstance() {
        SharedModelSpec.instancesConstructed.value = 0
        let taggedCommands: [(ScheduleMarker, SharedModelSpec.Command)] = [
            (.prefix, .record(amount: 1)),
            (ScheduleMarker(rawValue: 1), .record(amount: 10)),
            (ScheduleMarker(rawValue: 2), .record(amount: 100)),
        ]
        let outcome = PreemptiveChecker<SharedModelSpec>(idleTimeoutMilliseconds: nil).execute(
            taggedCommands,
            setupStep: nil,
            partition: LanePartition(markers: taggedCommands.map(\.0))
        )

        guard case .passed = outcome else {
            Issue.record("Every command's writes commute and both totals are synchronized, so the probe should pass whatever order the lanes took, not \(outcome)")
            return
        }
        #expect(
            SharedModelSpec.instancesConstructed.value == 2,
            "One instance for the lanes to share and one for the reference replay. A third would mean the runner had built one per lane"
        )
    }

    /// An invariant that fails while one command runs at a time fails without any interleaving, so the sequence is a deterministic counterexample rather than an ordering question. The probe must say so directly: no oracle comparison, no interleaving search.
    @Test("An invariant that fails on the sequential reference replay reports a deterministic failure")
    func anInvariantThatFailsOnTheSequentialReferenceReplayReportsADeterministicFailure() {
        let taggedCommands: [(ScheduleMarker, BoundedTotalSpec.Command)] = [
            (ScheduleMarker(rawValue: 1), .add),
            (ScheduleMarker(rawValue: 2), .add),
        ]
        let outcome = PreemptiveChecker<BoundedTotalSpec>(idleTimeoutMilliseconds: nil).execute(
            taggedCommands,
            setupStep: nil,
            partition: LanePartition(markers: taggedCommands.map(\.0))
        )

        guard case .failed = outcome else {
            Issue.record("Two adds exceed the bound in any order, so the probe should report a deterministic failure, not \(outcome)")
            return
        }
    }

    /// The control for the reference replay: the same spec, one command short of its bound. The replay's invariants hold, the synchronized system under test matches the reference, and the probe passes.
    @Test("A sequence whose invariants hold under sequential replay reaches the oracle and passes")
    func aSequenceWhoseInvariantsHoldUnderSequentialReplayReachesTheOracleAndPasses() {
        let taggedCommands: [(ScheduleMarker, BoundedTotalSpec.Command)] = [
            (ScheduleMarker(rawValue: 1), .add),
        ]
        let outcome = PreemptiveChecker<BoundedTotalSpec>(idleTimeoutMilliseconds: nil).execute(
            taggedCommands,
            setupStep: nil,
            partition: LanePartition(markers: taggedCommands.map(\.0))
        )

        guard case .passed = outcome else {
            Issue.record("One add stays within the bound, so the probe should pass, not \(outcome)")
            return
        }
    }

    /// Invariants are consulted inside the interleaving search, not only before it. Both commands push the sentinel or follow it, so every ordering passes through a state the invariant rejects and the search finds no explanation.
    @Test("An invariant that no ordering satisfies makes the history non-linearizable")
    func anInvariantThatNoOrderingSatisfiesMakesTheHistoryNonLinearizable() throws {
        let taggedCommands: [(ScheduleMarker, SentinelFreePushSpec.Command)] = [
            (ScheduleMarker(rawValue: 1), .push(value: sentinelValue)),
            (ScheduleMarker(rawValue: 2), .push(value: 1)),
        ]
        // Stands in for the instance the lanes ran on: its log holds both pushes, so the oracle accepts either ordering and the invariant is the only judgement left.
        let concurrentSpec = SentinelFreePushSpec()
        try concurrentSpec.run(.push(value: sentinelValue))
        try concurrentSpec.run(.push(value: 1))

        let result = PreemptiveChecker<SentinelFreePushSpec>(idleTimeoutMilliseconds: nil).checkLinearizability(
            taggedCommands: taggedCommands,
            setupStep: nil,
            laneResponses: voidResponses(for: taggedCommands),
            concurrentSpec: concurrentSpec
        )

        guard case .notLinearizable = result else {
            Issue.record("Every ordering pushes the sentinel, so no ordering explains the run")
            return
        }
    }

    /// The behavior that keeps the search useful: an invariant failure rejects the ordering being built, not the check. The search tries lane a first at every depth, so it reaches the descending order and its rejected invariant before the ascending one, which satisfies everything.
    @Test("An invariant that fails on one candidate ordering rejects that ordering and the search continues")
    func anInvariantThatFailsOnOneCandidateOrderingRejectsThatOrderingAndTheSearchContinues() throws {
        let taggedCommands: [(ScheduleMarker, AscendingPushSpec.Command)] = [
            (ScheduleMarker(rawValue: 1), .push(value: 2)),
            (ScheduleMarker(rawValue: 2), .push(value: 1)),
        ]
        // The oracle compares multisets, so it cannot tell the two orderings apart and the invariant decides which survives.
        let concurrentSpec = AscendingPushSpec()
        try concurrentSpec.run(.push(value: 2))
        try concurrentSpec.run(.push(value: 1))

        let result = PreemptiveChecker<AscendingPushSpec>(idleTimeoutMilliseconds: nil).checkLinearizability(
            taggedCommands: taggedCommands,
            setupStep: nil,
            laneResponses: voidResponses(for: taggedCommands),
            concurrentSpec: concurrentSpec
        )

        guard case .linearizable = result else {
            Issue.record("Pushing 1 then 2 satisfies the invariant, the responses, and the oracle, so the search should have found it")
            return
        }
    }
}

// MARK: - Specs

/// A spec whose model is deliberately thread-safe, written the way the mode invites: commands run concurrently against this instance, and the model is built to take it.
///
/// Its equivalence claims the model and the system under test hold the same total. Both are synchronized and both take commuting writes, so the claim holds under every interleaving — and only while the lanes share this instance. It also counts its own constructions, which is what tells a test how many instances a probe built.
@StateMachine
final class SharedModelSpec {
    /// Instances constructed since a test last reset it, counted under a lock because the runner builds them from its own threads.
    static let instancesConstructed = SendableBox(0)

    var expected = LockedTotal()
    @SystemUnderTest
    var total = LockedTotal()

    @Equivalence
    func sameTotal(as other: LockedTotal) -> Bool {
        total.value == other.value && expected.value == total.value
    }

    @Command(.int(in: 1 ... 100))
    func record(amount: Int) throws {
        expected.add(amount)
        total.add(amount)
    }

    func failureDescription() -> String? {
        "expected: \(expected.value), total: \(total.value)"
    }

    init() {
        Self.instancesConstructed.withValue { $0 += 1 }
    }
}

/// A counter with a cap the model claims it never passes. The system under test is synchronized, so the only way to break the claim is to run more commands than the cap allows, which a sequential replay does as readily as a concurrent one.
@StateMachine
final class BoundedTotalSpec {
    var expected = 0
    @SystemUnderTest
    var total = LockedTotal()

    @Invariant
    func totalStaysWithinItsCap() -> Bool {
        total.value <= 1
    }

    @Equivalence
    func sameTotal(as other: LockedTotal) -> Bool {
        total.value == other.value
    }

    @Command
    func add() throws {
        expected += 1
        total.add()
    }

    func failureDescription() -> String? {
        "expected: \(expected), total: \(total.value)"
    }
}

/// Claims the log never holds the sentinel value, which is false of every ordering of a sequence that pushes it.
@StateMachine
final class SentinelFreePushSpec {
    var pushed: [Int] = []
    @SystemUnderTest
    var log = ModelValueLog()

    @Invariant
    func logIsSentinelFree() -> Bool {
        pushed.contains(sentinelValue) == false
    }

    @Equivalence
    func sameMultiset(as other: ModelValueLog) -> Bool {
        log.values.sorted() == other.values.sorted()
    }

    @Command(.int(in: 1 ... 9))
    func push(value: Int) throws {
        pushed.append(value)
        log.append(value)
    }

    func failureDescription() -> String? {
        "pushed: \(pushed)"
    }
}

/// Claims the pushed values are ascending, which one ordering of a two-push sequence satisfies and the other does not. The equivalence compares multisets so it cannot tell the two apart.
@StateMachine
final class AscendingPushSpec {
    var pushed: [Int] = []
    @SystemUnderTest
    var log = ModelValueLog()

    @Invariant
    func pushedIsAscending() -> Bool {
        pushed == pushed.sorted()
    }

    @Equivalence
    func sameMultiset(as other: ModelValueLog) -> Bool {
        log.values.sorted() == other.values.sorted()
    }

    @Command(.int(in: 1 ... 9))
    func push(value: Int) throws {
        pushed.append(value)
        log.append(value)
    }

    func failureDescription() -> String? {
        "pushed: \(pushed)"
    }
}

// MARK: - Supporting Types

/// The value ``SentinelFreePushSpec`` claims never reaches the log.
private let sentinelValue = 9

/// An append-only log of integers, safe for concurrent appends so that a lost record can never be mistaken for a lane writing to a different instance.
final class ModelValueLog: @unchecked Sendable, CustomDebugStringConvertible {
    private let lock = NSLock()
    private var storedValues: [Int] = []

    var values: [Int] {
        lock.withLock { storedValues }
    }

    var debugDescription: String {
        "ModelValueLog(values: \(values))"
    }

    func append(_ value: Int) {
        lock.withLock { storedValues.append(value) }
    }
}

/// A counter whose increments are serialized, so a probe over it fails only for reasons the spec's own claims explain.
final class LockedTotal: @unchecked Sendable, CustomDebugStringConvertible {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.withLock { storedValue }
    }

    var debugDescription: String {
        "LockedTotal(value: \(value))"
    }

    func add(_ amount: Int = 1) {
        lock.withLock { storedValue += amount }
    }
}

// MARK: - Helpers

/// Builds per-lane observations for commands that answer nothing, one lane per tagged command in marker order.
private func voidResponses<Command>(
    for taggedCommands: [(ScheduleMarker, Command)]
) -> [[ObservedResponse<Command>]] {
    taggedCommands
        .filter { $0.0.isPrefix == false }
        .map { marker, command in
            [ObservedResponse(lane: marker.rawValue, command: command, outcome: .returnedVoid)]
        }
}
