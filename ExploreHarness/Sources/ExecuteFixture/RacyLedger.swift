// The cooperative-interleaving archetype: the first fixture whose fault lives in the schedule, not the command values. Exists to validate the `.tasks` path of `#execute(time:)` — lane markers are choices in the sequence, so the search mutates the interleaving with the same operators that mutate commands.
//
// ## Shape Coordinates
//
// Trigger class: lost update — two read-modify-write commands whose suspension windows overlap. Coverage surface: the deposit/audit branches give the search structure, but the fault itself is schedule-gated, not value-gated. Vocabulary: three commands. Argument domain: deposit amounts 1...9. Length scale: the minimal trigger is two deposits on distinct lanes with an overlapping suspension window.
//
// ## Ground-Truth Registry
//
// Fault L (lost update):
//     Trigger: two `deposit` commands on different lanes interleaved so both read the balance before either writes it back. The suspension point between read and write is the planted race.
//     Trigger variable: the schedule markers — no argument values participate.
//     Minimal: [deposit on lane a, deposit on lane b] with the schedule realizing read-read-write-write.
//     Effect: the ledger's balance diverges from the spec's model, detected by the `balanceMatchesModel` invariant.
//     Sequential soundness: any all-prefix (single-lane) execution runs each read-modify-write to completion before the next command starts, so the fault is unreachable without interleaving. `TasksFuzzTests` pins this with a one-lane negative control.

/// A ledger whose deposits are deliberately non-atomic: the balance read and write are separated by a suspension point.
public final class RacyLedger: @unchecked Sendable {
    private var balance: Int = 0
    private var depositCount: Int = 0

    public init() {}

    /// The current balance, exposed for the spec's invariant and failure reports.
    public var currentBalance: Int {
        balance
    }

    // MARK: - Commands

    /// Adds `amount` to the balance through a read-modify-write with a suspension point in the middle — fault L's planted race.
    public func deposit(_ amount: Int) async {
        let read = balance
        await Task.yield()
        balance = read + amount
        depositCount += 1
    }

    /// Resets the ledger. Atomic: no suspension point, so it cannot participate in fault L.
    public func reset() {
        balance = 0
        depositCount = 0
    }

    /// Summarizes the ledger; the branches exist so the coverage surface has structure beyond the deposit path.
    public func audit() -> (balance: Int, deposits: Int, isEmpty: Bool) {
        if depositCount == 0 {
            return (balance, 0, true)
        }
        if balance == 0 {
            return (0, depositCount, false)
        }
        return (balance, depositCount, false)
    }
}
