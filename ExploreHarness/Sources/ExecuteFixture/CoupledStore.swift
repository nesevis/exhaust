// The cross-command value-coupling archetype (matrix fixture MX1c, "CoupledValues"): the trigger couples one command's argument to a value another command stored earlier, so command-mix mechanisms have purchase the latch's single-command shape denies them.
//
// ## Shape Coordinates
//
// Trigger class: cross-command value coupling. Coverage surface: gradient-free — the key equality lights no edge that correlates with progress toward the fault (a match either fires immediately or, when younger than the distance gate, lights an edge that accumulates nothing). Vocabulary: three commands, uniform weight. Argument domains: key 0...15, padding 0...9. Length scale: minimal trigger is 5 commands, far inside the limit.
//
// ## Ground-Truth Registry
//
// Fault C (coupled probe):
//     Trigger: a probe whose argument equals the stored key, where the matching setKey landed at least `requiredDistance` (3) commands earlier. A later setKey restarts the distance clock; pad advances it.
//     Trigger variable: the (storedKey, keySetIndex) pair against the probe argument and the running command index.
//     Minimal: [setKey(k), pad(0), pad(0), pad(0), probe(k)] for any k.
//     Effect: sets isCorrupted, detected by the spec's notCorrupted invariant.
//
// Single planted fault; no other fixture state exists.
//
// ## Blind Rate (deliberately probable)
//
// Monte Carlo over uniform spec-shaped sequences (lengths 0...40): fault C fires in ~13% of attempts — the 16-value key domain is the small-enum point on the argument-domain axis, so the coupling is blind-findable by design. C is a regression-detection sentinel for the value-coupling class (the >= 18/20 side of the calibration window), not a mechanism differential; a future differential for this class would widen the domain instead.
//
// Pinned baseline (MX1g, 2026-07-12, seeds 1-20, 10 s, defaults, .commandLimit(40)): 20/20.

/// A single-key store whose fault couples a probe argument to a key stored at least three commands earlier.
public struct CoupledStore: Sendable {
    /// Set once fault C fires; the planted fault's observable effect.
    public private(set) var isCorrupted = false

    /// The most recent padding value, surfaced for failure reports.
    public private(set) var lastPadding = 0

    /// -1 never matches the 0...15 key domain, so no probe can fire before the first setKey.
    private var storedKey = -1

    /// Command index of the most recent setKey; -1 before the first.
    private var keySetIndex = -1

    /// Advances on every command, branchlessly.
    private var commandIndex = 0

    private let requiredDistance: Int

    public init(requiredDistance: Int = 3) {
        self.requiredDistance = requiredDistance
    }

    /// The stored key, exposed for smoke tests and failure reports.
    public var currentKey: Int {
        storedKey
    }

    // MARK: - Commands

    /// Stores the key and restarts the distance clock.
    public mutating func setKey(_ key: Int) {
        storedKey = key
        keySetIndex = commandIndex
        commandIndex += 1
    }

    /// Fires fault C when the argument matches the stored key and the matching `setKey` landed far enough back.
    public mutating func probe(_ key: Int) {
        // Fault C: the equality lights no progress-correlated edge — a match either fires here or is younger than the distance gate.
        if key == storedKey, commandIndex - keySetIndex >= requiredDistance {
            isCorrupted = true
        }
        commandIndex += 1
    }

    /// Records a padding value and advances the distance clock.
    public mutating func pad(_ value: Int) {
        lastPadding = value
        commandIndex += 1
    }
}
