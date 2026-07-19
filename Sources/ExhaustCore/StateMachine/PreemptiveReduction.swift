/// Provides the tuning constants for preemptive concurrent spec testing.
///
/// The two preemptive backends (synchronous and async) differ only in how a single probe runs; the repetition scaling, command limit, and warning thresholds they share are backend-independent and live here.
package enum PreemptiveReduction {
    /// Maximum confirmation repetitions, used for failures discovered within 1,000 iterations.
    package static let confirmationRepetitionsCeiling = 100

    /// Minimum confirmation repetitions, used for failures discovered at or beyond 10,000 iterations.
    package static let confirmationRepetitionsFloor = 25

    /// Computes the number of confirmation repetitions per reduction probe, scaled by how quickly the failure was discovered.
    ///
    /// Failures found within 1,000 total iterations (screening + sampling) get ``confirmationRepetitionsCeiling`` repetitions. The count scales linearly down to ``confirmationRepetitionsFloor`` by 10,000 iterations, then stays at the floor. Races that reproduce easily (low iteration count) get more attempts per probe, so the reducer can confidently strip commands. Races that took many iterations to surface are inherently harder to reproduce, and additional repetitions beyond the floor yield diminishing returns against the per-probe cost.
    package static func confirmationRepetitions(discoveryIterations: Int) -> Int {
        if discoveryIterations <= 1000 {
            return confirmationRepetitionsCeiling
        }
        if discoveryIterations >= 10000 {
            return confirmationRepetitionsFloor
        }
        let range = confirmationRepetitionsCeiling - confirmationRepetitionsFloor
        let scaled = range * (discoveryIterations - 1000) / (10000 - 1000)
        return confirmationRepetitionsCeiling - scaled
    }

    /// Computes the number of terminal confirmation repetitions, scaled by how quickly the failure was discovered.
    ///
    /// The terminal confirmation runs once per reported failure (not per reduction probe), so it can afford more attempts than the per-probe count. Uses three times the per-probe count, floored at 150 — easy races get up to 300 attempts to attach the actual-state evidence line, while hard races stay at 150 (where more attempts would be wasted anyway).
    package static func finalConfirmationRepetitions(discoveryIterations: Int) -> Int {
        max(150, confirmationRepetitions(discoveryIterations: discoveryIterations) * 3)
    }

    /// Default command limit for `.threads` specs.
    package static let defaultCommandLimit = 10

    /// Worst-case interleaving count above which the runner emits a warning before starting the pipeline. The DFS is exhaustive, so configurations that exceed this threshold can make each linearizability check very slow.
    package static let interleavingWarningThreshold = 1_000_000_000

    /// Fraction of the configured budget that, once reached as timed-out probes, triggers a runtime warning. A probe that times out counts as a pass so discovery stays resilient under host contention, but a high timeout rate means most of the budget produced no useful signal — a saturated machine or a genuinely hanging system — so the runner surfaces it rather than passing silently.
    package static let timeoutWarningFraction = 0.25
}
