// The order-gated archetype (matrix fixture MX1a, "PhaseProtocol"): the trigger is an ordered subsequence, not a count — the class where mutation's block operators must assemble structure rather than just delete it.
//
// ## Shape Coordinates
//
// Trigger class: phase-protocol order gate. Coverage surface: flat by default, laddered via `laddered: true` (one edge per completed-cycle rung). Vocabulary: five commands, uniform weight, one small-enum argument domain (configure's 0...9). Length scale: minimal trigger is 3 x requiredCycles + 1 commands — well inside the default command limit of 40 at the calibrated cycle count.
//
// ## Ground-Truth Registry
//
// Fault O (order-gated corruption):
//     Trigger: `use` while the session is closed after at least `requiredCycles` completed open→use→close cycles (a cycle completes when a close lands after at least one use in the same open period; `reset` zeroes the cycle count).
//     Trigger variable: completedCycles (tracked arithmetically — see Flatness below).
//     Minimal at requiredCycles = 5: [open, use, close] x5 followed by one use.
//     Effect: sets isCorrupted, detected by the spec's notCorrupted invariant.
//
// Single planted fault; no other fixture state exists, so trigger disjointness is trivial.
//
// ## Flatness
//
// The flat variant must light no edge that correlates with cycle progress, or hit-count buckets ladder the cycle count for free (the SF6 constraint). Phase transitions and cycle completion are therefore pure arithmetic: `max`/`min` calls live in the uninstrumented standard library, `close()` adds `usedThisCycle` unconditionally, and the fault check nests the cycle comparison inside the use-while-closed branch so the inner edge lights only when the fault fires. The laddered variant converts the same accumulation into stepwise extension: each completed-cycle rung lights a distinct edge.
//
// ## Blind-Improbability Math
//
// Exact DP over the five-command uniform chain (state: phase x usedThisCycle x capped cycle count): at requiredCycles = 5 the trigger probability is 5.0e-6 for a 40-command sequence and 7.3e-7 averaged over the uniform 0...40 length draw. At the design document's starting constant of 2 cycles the DP gives 7.8e-3 per attempt — found blind within the first few hundred attempts, hopelessly outside the calibration window at ~5000 attempts/s — so the starting constant here is 5, finalized by the MX1g calibration sweep.
//
// Pinned baselines (MX1g, 2026-07-12, seeds 1-20, 10 s, defaults, .commandLimit(40)): flat 0/20, laddered 19/20.

/// A session object whose misuse fault requires an ordered command subsequence: several completed open→use→close cycles, then a stray `use` while closed.
public struct PhaseSession: Sendable {
    /// Set once fault O fires; the planted fault's observable effect.
    public private(set) var isCorrupted = false

    /// The most recent `configure` setting, surfaced for failure reports.
    public private(set) var lastSetting = 0

    /// Phase encoded as an integer (0 closed, 1 open, 2 configured) so transitions stay branchless in fixture code.
    private var phaseRaw = 0

    /// 1 once a `use` lands in the current open period, 0 otherwise.
    private var usedThisCycle = 0

    /// Fault O trigger variable.
    private var completedCycles = 0

    /// Highest ladder rung reached (laddered variant only); exists so rung edges assign state rather than being empty branches.
    private var ladderRung = 0

    private let laddered: Bool
    private let requiredCycles: Int

    public init(laddered: Bool = false, requiredCycles: Int = 5) {
        precondition(
            laddered == false || requiredCycles <= PhaseSession.ladderRungLimit,
            "the laddered variant has \(PhaseSession.ladderRungLimit) distinct rung edges; requiredCycles \(requiredCycles) would leave the top of the ladder unlit — extend recordLadderRung before raising the trigger"
        )
        self.laddered = laddered
        self.requiredCycles = requiredCycles
    }

    /// The phase name for failure reports.
    public var phaseName: String {
        ["closed", "open", "configured"][phaseRaw]
    }

    /// The completed-cycle count, exposed for smoke tests and failure reports.
    public var cycleCount: Int {
        completedCycles
    }

    // MARK: - Commands

    /// Opens the session; a no-op when already open or configured.
    public mutating func open() {
        phaseRaw = max(phaseRaw, 1)
    }

    /// Records the setting and moves an open session to configured; a closed session stays closed.
    public mutating func configure(_ setting: Int) {
        lastSetting = setting
        // closed stays closed (0), open and configured both map to configured (2).
        phaseRaw = min(phaseRaw, 1) * 2
    }

    /// Marks the current open period as used, or fires fault O when called while closed after enough completed cycles.
    public mutating func use() {
        if phaseRaw == 0 {
            // Fault O: use while closed, after enough completed cycles. The outer branch is hit from the first stray use; the inner edge lights only when the fault fires, so cycle progress lights nothing.
            if completedCycles >= requiredCycles {
                isCorrupted = true
            }
            return
        }
        usedThisCycle = 1
    }

    /// Closes the session, completing a cycle when a `use` landed in the open period.
    public mutating func close() {
        // A cycle completes when a close lands after a use in the same open period. Unconditional arithmetic: no edge correlates with the cycle count in the flat variant.
        completedCycles += usedThisCycle
        usedThisCycle = 0
        phaseRaw = 0
        if laddered {
            recordLadderRung()
        }
    }

    /// Returns the session to its initial state, zeroing the cycle count.
    public mutating func reset() {
        phaseRaw = 0
        usedThisCycle = 0
        completedCycles = 0
        ladderRung = 0
    }

    // MARK: - Ladder

    /// The highest distinct rung edge `recordLadderRung` can light. The initializer refuses a laddered session whose `requiredCycles` exceeds this, so a calibration retune can never silently leave the top of the ladder unlit (each rung must be its own `case` to be its own edge, so the cap is structural).
    public static let ladderRungLimit = 8

    /// One distinct edge per completed-cycle rung: converts cycle accumulation into the stepwise extension coverage-guided mutation solves (the SF6 ladder shape).
    private mutating func recordLadderRung() {
        switch min(completedCycles, PhaseSession.ladderRungLimit) {
            case 1: ladderRung = max(ladderRung, 1)
            case 2: ladderRung = max(ladderRung, 2)
            case 3: ladderRung = max(ladderRung, 3)
            case 4: ladderRung = max(ladderRung, 4)
            case 5: ladderRung = max(ladderRung, 5)
            case 6: ladderRung = max(ladderRung, 6)
            case 7: ladderRung = max(ladderRung, 7)
            case 8: ladderRung = max(ladderRung, 8)
            default: break
        }
    }
}
