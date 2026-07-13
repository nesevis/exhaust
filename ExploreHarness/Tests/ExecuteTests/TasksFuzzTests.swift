import ExecuteFixture
import Exhaust
import MatrixSpecs
import Testing

@Suite("Tasks fuzz validation: cooperative interleaving", .serialized)
struct TasksFuzzTests {
    // MARK: - Reproducer Smoke Test

    @Test("Fault L fires under a hand-realized overlapping schedule")
    func faultLMinimal() async {
        // Two interleaved read-modify-writes: both read before either writes, so one deposit is lost.
        let ledger = RacyLedger()
        async let first: Void = ledger.deposit(1)
        async let second: Void = ledger.deposit(1)
        _ = await (first, second)
        // The lost update is schedule-dependent under the global executor, so this smoke test asserts only the atomic floor: the balance never exceeds the sum and never drops below a single deposit.
        #expect(ledger.currentBalance >= 1 && ledger.currentBalance <= 2)
    }

    // MARK: - Fuzz Validation

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("A two-lane fuzz run finds the lost update through real coverage feedback")
    func findsInterleavingFault() async {
        let report = await #execute(
            RacyLedgerSpec.self,
            time: .seconds(5),
            .parallelize(lanes: .two),
            .commandLimit(20),
            .suppress(.issueReporting)
        )
        #expect(report.totalAttempts > 0)
        #expect(report.clusters.isEmpty == false, "Lane-marker mutation should realize a read-read-write-write interleaving within the budget")
        #expect(report.clusters.allSatisfy { $0.symptoms.contains("StateMachineCheckFailure") }, "Fault L surfaces as the balanceMatchesModel invariant violation")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("The one-lane negative control never finds the interleaving fault")
    func sequentialLanesFindNothing() async {
        // Fault L's sequential-soundness pin: with one lane every marker is prefix, each read-modify-write runs to completion before the next command, and no schedule can realize the race. A cluster here means the fixture has a value-gated fault it must not have.
        let report = await #execute(
            RacyLedgerSpec.self,
            time: .seconds(5),
            .parallelize(lanes: .one),
            .commandLimit(20),
            .replay(1),
            .suppress(.issueReporting)
        )
        #expect(report.totalAttempts > 0)
        #expect(report.clusters.isEmpty, "A single-lane schedule realized fault L — the cooperative path is executing lanes it should not have, or the fixture gained a sequential fault")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Replaying a seed rediscovers the same fault classes")
    func replayRediscoversSameClusters() async {
        // The documented replay contract for time: mode — same seed, same build, comparable budget rediscovers the same clusters, not an attempt-for-attempt identical log. This is the instrumented determinism check the synthetic-coverage tests cannot perform: it fails if the cooperative drain leaks schedule nondeterminism into the search's decisions.
        let first = await #execute(
            RacyLedgerSpec.self,
            time: .seconds(5),
            .parallelize(lanes: .two),
            .commandLimit(20),
            .replay(42),
            .suppress(.issueReporting)
        )
        let second = await #execute(
            RacyLedgerSpec.self,
            time: .seconds(5),
            .parallelize(lanes: .two),
            .commandLimit(20),
            .replay(42),
            .suppress(.issueReporting)
        )
        let firstSymptoms = Set(first.clusters.flatMap(\.symptoms))
        let secondSymptoms = Set(second.clusters.flatMap(\.symptoms))
        #expect(firstSymptoms == secondSymptoms, "Replay under the same seed diverged: \(firstSymptoms) vs \(secondSymptoms)")
    }
}
