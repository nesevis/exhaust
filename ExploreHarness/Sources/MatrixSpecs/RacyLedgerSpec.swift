import ExecuteFixture
import Exhaust

/// The shared spec for the `RacyLedger` fixture (fault L — registry in `RacyLedger.swift`).
///
/// The only `.tasks` spec in the harness: its commands are async so the cooperative scheduler can interleave them at the fixture's planted suspension point. The model updates `expected` synchronously before each await, so a completed sequential execution always matches — divergence requires an overlapping read-modify-write, which only a cross-lane schedule can realize.
@StateMachine(.tasks)
public final class RacyLedgerSpec {
    var expected: Int = 0
    @SystemUnderTest var ledger: RacyLedger = .init()

    @Invariant
    func balanceMatchesModel() -> Bool {
        ledger.currentBalance == expected
    }

    @Command(weight: 3, .int(in: 1 ... 9))
    func deposit(amount: Int) async throws {
        expected += amount
        await ledger.deposit(amount)
    }

    @Command(weight: 1)
    func reset() async throws {
        expected = 0
        ledger.reset()
    }

    @Command(weight: 1)
    func audit() async throws {
        let summary = ledger.audit()
        guard summary.isEmpty == false || summary.balance == 0 else {
            throw RacyLedgerError.inconsistentAudit
        }
    }

    /// Reports the SUT and model balances at the point of failure.
    public func failureDescription() -> String? {
        "ledger: \(ledger.currentBalance), model: \(expected)"
    }
}

/// Thrown when an audit reports an empty ledger with a non-zero balance; unreachable by design, present so the audit branch has a consequence.
public enum RacyLedgerError: Error {
    case inconsistentAudit
}
