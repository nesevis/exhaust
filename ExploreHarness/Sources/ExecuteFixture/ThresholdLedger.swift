// The joint capacity+value gate and length-axis archetype (matrix fixture MX1e, "ThresholdLedger"): the fault needs enough qualifying accumulates without an intervening spend, and the two threshold configurations place the minimal trigger comfortably inside versus near the default command limit — the axis that exposes the champion-archive/accumulation tension and the axis masking cannot influence.
//
// ## Shape Coordinates
//
// Trigger class: joint capacity+value accumulation. Coverage surface: flat by default (see Flatness), laddered via `laddered: true` (one edge per sum quartile). Vocabulary: three commands, uniform weight. Argument domain: accumulate value 0...9, where only 6...9 qualify. Length scale: threshold 40 needs ~6 qualifying accumulates (~13 accumulate commands at the 0.4 qualifying rate) — comfortably inside the limit; threshold 90 needs ~12 qualifying (~30 commands) — near it, where the champion archive's short-parent pressure and the ~20 mean generated length both bite.
//
// ## Ground-Truth Registry
//
// Fault J (unspent accumulation):
//     Trigger: running sum >= threshold, fired at the crossing accumulate; spend zeroes the sum, audit only reads it.
//     Trigger variable: balance.
//     Minimal at threshold 40: [accumulate(9)] x5 (sum 45); at threshold 90: [accumulate(9)] x10.
//     Effect: sets isCorrupted, detected by the spec's notCorrupted invariant.
//
// Single planted fault; no other fixture state exists.
//
// ## Flatness
//
// The qualifying-value filter is arithmetic — `(value / 6) * value` adds the value for 6...9 and zero for 0...5 — so no edge counts qualifying accumulates, and the fault comparison nests behind the crossing itself. The laddered variant lights one edge per sum quartile, converting the same accumulation into stepwise extension.
//
// ## Blind-Improbability Math
//
// Exact DP over the three-command uniform chain (state: capped balance): per attempt, threshold 40 fires at 8.6e-3 for a 40-command sequence (3.4e-3 averaged over the uniform 0...40 length draw) — deliberately mutation-assemblable, the "no differential expected" control of MX4 prediction 1. Threshold 90 fires at 1.3e-6 (3.0e-7 averaged) — the length-hostile configuration. Both constants are the design document's own; the MX1g calibration sweep finalizes them.
//
// Pinned baselines (MX1g, 2026-07-12, seeds 1-20, 10 s, defaults, .commandLimit(40)): threshold 40 flat 17/20, threshold 90 flat 0/20, threshold 90 laddered 19/20.

/// A running sum whose fault fires when enough qualifying deposits accumulate without an intervening spend.
public struct ThresholdLedger: Sendable {
    /// Set once fault J fires; the planted fault's observable effect.
    public private(set) var isCorrupted = false

    /// The most recent audited balance, surfaced for failure reports.
    public private(set) var lastAudit = 0

    /// Fault J trigger variable.
    private var balance = 0

    /// Highest quartile rung reached (laddered variant only).
    private var ladderRung = 0

    private let threshold: Int
    private let laddered: Bool

    public init(threshold: Int = 40, laddered: Bool = false) {
        self.threshold = threshold
        self.laddered = laddered
    }

    /// The current balance, exposed for smoke tests and failure reports.
    public var currentBalance: Int {
        balance
    }

    // MARK: - Commands

    /// Adds a qualifying value (6...9; lower values add nothing) to the balance, firing fault J at the threshold crossing.
    public mutating func accumulate(_ value: Int) {
        // Qualifying filter as arithmetic: (value / 6) is 1 for 6...9 and 0 for 0...5, so no edge counts qualifying accumulates.
        balance += (value / 6) * value
        if laddered {
            recordLadderRung()
        }
        // Fault J: fires at the crossing accumulate; the edge lights nothing until then.
        if balance >= threshold {
            isCorrupted = true
        }
    }

    /// Zeroes the balance, restarting the accumulation the fault requires.
    public mutating func spend() {
        balance = 0
    }

    /// Reads the balance without changing it; exists so sequences carry fault-irrelevant commands.
    public mutating func audit() {
        lastAudit = balance
    }

    // MARK: - Ladder

    /// One distinct edge per sum quartile: converts accumulation into the stepwise extension coverage-guided mutation solves (the SF6 ladder shape).
    private mutating func recordLadderRung() {
        switch min(balance * 4 / threshold, 3) {
            case 1: ladderRung = max(ladderRung, 1)
            case 2: ladderRung = max(ladderRung, 2)
            case 3: ladderRung = max(ladderRung, 3)
            default: break
        }
    }
}
