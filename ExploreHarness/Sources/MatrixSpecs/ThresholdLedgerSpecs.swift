import ExecuteFixture
import Exhaust

// The three specs below are deliberately identical except for the SUT's init arguments: #execute instantiates through the synthesized required init(), so configuration can only enter through the type, and @StateMachine discovers commands syntactically, ruling out a shared base. Change all three together.

/// The shared spec for the flat `ThresholdLedger` fixture at threshold 40 — the inside-the-command-limit configuration (fault J — registry in `ThresholdLedger.swift`).
@StateMachine(.sequential)
public final class ThresholdLedger40Spec {
    @SystemUnderTest var ledger: ThresholdLedger = .init(threshold: 40, laddered: false)

    @Invariant
    func notCorrupted() -> Bool {
        ledger.isCorrupted == false
    }

    @Command(weight: 1, .int(in: 0 ... 9))
    func accumulate(value: Int) throws {
        ledger.accumulate(value)
    }

    @Command(weight: 1)
    func spend() throws {
        ledger.spend()
    }

    @Command(weight: 1)
    func audit() throws {
        ledger.audit()
    }

    /// Reports the ledger state at the point of failure.
    public func failureDescription() -> String? {
        "balance: \(ledger.currentBalance), corrupted: \(ledger.isCorrupted)"
    }
}

/// The shared spec for the flat `ThresholdLedger` fixture at threshold 90 — the near-the-command-limit configuration where champion-archive short-parent pressure bites.
@StateMachine(.sequential)
public final class ThresholdLedger90Spec {
    @SystemUnderTest var ledger: ThresholdLedger = .init(threshold: 90, laddered: false)

    @Invariant
    func notCorrupted() -> Bool {
        ledger.isCorrupted == false
    }

    @Command(weight: 1, .int(in: 0 ... 9))
    func accumulate(value: Int) throws {
        ledger.accumulate(value)
    }

    @Command(weight: 1)
    func spend() throws {
        ledger.spend()
    }

    @Command(weight: 1)
    func audit() throws {
        ledger.audit()
    }

    /// Reports the ledger state at the point of failure.
    public func failureDescription() -> String? {
        "balance: \(ledger.currentBalance), corrupted: \(ledger.isCorrupted)"
    }
}

/// The laddered `ThresholdLedger` variant at threshold 90: identical command surface, but each sum quartile lights a distinct edge — the SF6 flat-versus-laddered contrast at the configuration where the flat variant is out of blind reach.
@StateMachine(.sequential)
public final class ThresholdLedger90LadderedSpec {
    @SystemUnderTest var ledger: ThresholdLedger = .init(threshold: 90, laddered: true)

    @Invariant
    func notCorrupted() -> Bool {
        ledger.isCorrupted == false
    }

    @Command(weight: 1, .int(in: 0 ... 9))
    func accumulate(value: Int) throws {
        ledger.accumulate(value)
    }

    @Command(weight: 1)
    func spend() throws {
        ledger.spend()
    }

    @Command(weight: 1)
    func audit() throws {
        ledger.audit()
    }

    /// Reports the ledger state at the point of failure.
    public func failureDescription() -> String? {
        "balance: \(ledger.currentBalance), corrupted: \(ledger.isCorrupted)"
    }
}
