// The parity/absence archetype (matrix fixture MX1d, "ToggleParity"): parity is the purest gradient-free signal — no count of edges distinguishes odd from even — and the fault needs presence (enough toggles) and a parity condition, unlike pure absence classes.
//
// ## Shape Coordinates
//
// Trigger class: toggle parity plus presence threshold. Coverage surface: flat — parity and the threshold comparison are pure arithmetic (see Flatness). Vocabulary: three commands, uniform weight. Argument domain: padding 0...9 only. Length scale: minimal trigger is 26 commands (25 toggles and a checkpoint) — inside the default limit of 40, but toggle-dense.
//
// ## Ground-Truth Registry
//
// Fault T (odd parity at depth):
//     Trigger: a checkpoint observing odd toggle parity with toggle count >= threshold (24). Count 24 is even, so the effective minimum is 25 toggles.
//     Trigger variable: toggleCount (both its magnitude and its low bit).
//     Minimal: [toggle] x25 followed by checkpoint.
//     Effect: sets isCorrupted, detected by the spec's notCorrupted invariant.
//
// Single planted fault; no other fixture state exists.
//
// ## Flatness
//
// Both trigger conditions collapse into one integer before the only branch: `min(max(0, count - threshold + 1), 1) & (count & 1)` is 1 exactly when the fault should fire (`min`/`max` live in the uninstrumented standard library). No branch on parity, no branch on the threshold alone — a checkpoint at count 30 with even parity lights nothing a checkpoint at count 2 does not.
//
// ## Blind-Improbability Math
//
// Exact DP over the three-command uniform chain: at threshold 24 the trigger probability is 3.5e-5 for a 40-command sequence and 1.7e-6 averaged over the uniform 0...40 length draw. The design document's starting constant of 7 gives 0.36 per attempt — found blind within the first few attempts — so the starting constant here is 24, finalized by the MX1g calibration sweep. Masking makes the fault mask-probable: an epoch masking `pad` (or `pad` and `checkpoint`) roughly doubles the per-command toggle probability, lifting the count tail by orders of magnitude.
//
// Pinned baseline (MX1g, 2026-07-12, seeds 1-20, 10 s, defaults, .commandLimit(40)): 0/20.

/// A toggle counter whose fault requires odd parity observed at a checkpoint after enough toggles.
public struct ToggleCounter: Sendable {
    /// Set once fault T fires; the planted fault's observable effect.
    public private(set) var isCorrupted = false

    /// The most recent padding value, surfaced for failure reports.
    public private(set) var lastPadding = 0

    /// Fault T trigger variable.
    private var toggleCount = 0

    private let threshold: Int

    public init(threshold: Int = 24) {
        self.threshold = threshold
    }

    /// The toggle count, exposed for smoke tests and failure reports.
    public var count: Int {
        toggleCount
    }

    // MARK: - Commands

    /// Increments the toggle count, flipping its parity.
    public mutating func toggle() {
        toggleCount += 1
    }

    /// Observes the counter, firing fault T when the count is odd and at or over the threshold.
    public mutating func checkpoint() {
        // Fault T: threshold presence and odd parity, folded into one integer so the only branch lights when the fault fires.
        let overThreshold = min(max(0, toggleCount - threshold + 1), 1)
        let armed = overThreshold & (toggleCount & 1)
        if armed == 1 {
            isCorrupted = true
        }
    }

    /// Records a padding value; exists so sequences carry fault-irrelevant commands.
    public mutating func pad(_ value: Int) {
        lastPadding = value
    }
}
