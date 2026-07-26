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

    /// Worst-case interleaving count above which the runner emits a warning before starting the pipeline.
    ///
    /// Derived from the search's measured cost rather than chosen as a round number. The DFS replays the prefix once per complete ordering and executes every command in it, so a history with *I* orderings and *n* commands costs `I · n` command replays when nothing prunes early (the void-command case, where responses carry no information and only the final-state oracle can reject). Holding one check to roughly a second at a microsecond per replay puts the ceiling near 10⁶ replays, so the threshold is 10⁵ orderings.
    ///
    /// Do not raise this toward a rounder number: a threshold of 10⁹ cannot fire before `commandLimit` 33 on two lanes, by which point a single check is on the order of 10¹⁰ command replays, and a warning that cannot fire before the configuration becomes unusable reads as reassurance.
    package static let interleavingWarningThreshold = 100_000

    /// Command replays one linearizability check may perform before abandoning the search.
    ///
    /// The DFS is exponential and nothing else bounds it: the reduction deadline bounds the reducer, and the idle timeout bounds the concurrent execution, but a single oracle-flagged probe can otherwise search until the process is killed. At roughly a microsecond per replay this is a few seconds of searching.
    ///
    /// A sibling retry replays the sequential prefix on a fresh spec before re-placing the ordering, so a prefix replay is charged its own command count (at least one, for the spec construction and setup that happen even with an empty prefix). Charging only the concurrent commands would let a long prefix multiply the search's real cost by a factor invisible to the budget.
    ///
    /// A replay count rather than a wall-clock deadline, deliberately: the same history reaches the same verdict on every machine and on every replay of a seed, where a clock would flip verdicts under load. The cost is that the wall-clock bound scales with the spec's per-command cost — a command that takes a millisecond to replay stretches the budget to roughly half an hour — so the bound is against runaway search, not a latency guarantee.
    ///
    /// Exhausting the budget resolves as linearizable, matching the policy for a timed-out probe: an inconclusive result must never be reported as a counterexample. The checker logs when this happens so a run that keeps abandoning searches is visible rather than silently passing.
    package static let linearizabilitySearchReplayBudget = 2_000_000

    /// Fraction of the configured budget that, once reached as timed-out probes, triggers a runtime warning. A probe that times out counts as a pass so discovery stays resilient under host contention, but a high timeout rate means most of the budget produced no useful signal — a saturated machine or a genuinely hanging system — so the runner surfaces it rather than passing silently.
    package static let timeoutWarningFraction = 0.25
}
