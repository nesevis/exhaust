// The negative-control SUT: one planted fault that coverage-guided search is expected NOT to find.
//
// Purpose (see ExhaustDocs/fuzzer-selftest-sut-landscape.md, item 3): the harness needs a fixture documenting the mode's honest limits, the way libFuzzer's SimpleHashTest does. The fault is blind-improbable and gradient-free by construction — the SF6 corrected requirements minus the mask-probable clause. A future feedback channel (spec-state feedback, value profile) passes its gate by flipping this fixture's fuzz test from not-found to found at matched budget.
//
// ## Ground-Truth Registry
//
// Fault N (gradient-free consecutive latch):
//     Trigger: 10 consecutive pulse(7) calls; any other digit resets the streak.
//     Trigger variable: consecutiveArmingPulses (invisible to edge coverage: the digit == 7 branch is hit trivially from the first attempt, the trip branch lights only when the fault fires, and no edge correlates with streak progress).
//     Minimal: [pulse(7)] x10.
//     Effect: sets isTripped, detected by the spec's neverTripped invariant.
//
// ## Blind-Improbability Math
//
// P(digit == 7) = 1/10 per pulse under the spec's uniform 0...9 generator, so one aligned 10-slot window trips with probability 1e-10. A 40-command sequence holds 31 windows (~3.1e-9 per attempt), and corpus admission never preserves streak progress because no edge lights as the streak climbs — mutation cannot compound partial alignment.

public struct ConsecutiveLatch: Sendable {
    /// Set once the latch trips; the planted fault's observable effect.
    public private(set) var isTripped = false

    /// Fault N trigger: the current run of consecutive arming pulses.
    private var consecutiveArmingPulses = 0

    public init() {}

    public mutating func pulse(_ digit: Int) {
        if digit == 7 {
            consecutiveArmingPulses += 1
            // Fault N: fires on the tenth consecutive arming pulse. The firing itself lights the only streak-correlated edge.
            if consecutiveArmingPulses >= 10 {
                isTripped = true
            }
        } else {
            consecutiveArmingPulses = 0
        }
    }
}
