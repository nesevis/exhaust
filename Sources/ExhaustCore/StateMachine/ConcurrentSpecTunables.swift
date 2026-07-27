/// Provides the tuning constants shared by every concurrent spec run, regardless of which scheduler drives the lanes.
///
/// Task-based and thread-based runs judge concurrency the same way — a linearizability search over recorded responses — so the search budget, its warning threshold, the command limit that keeps the search tractable, and the timeout-warning fraction are scheduler-independent and live here. Policy that only the preemptive runners use (confirmation repetition scaling) lives in ``PreemptiveConfirmation``.
package enum ConcurrentSpecTunables {
    /// Default command limit for runs that pay for a linearizability search: thread-based runs, and task-based runs whose spec declares an equivalence.
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
    /// Exhausting the budget resolves as linearizable, matching the policy for a timed-out probe: an inconclusive result must never be reported as a counterexample. The checker reports when this happens so a run that keeps abandoning searches is visible rather than silently passing.
    package static let linearizabilitySearchReplayBudget = 2_000_000

    /// Fraction of the configured budget that, once reached as timed-out probes, triggers a runtime warning. A probe that times out counts as a pass so discovery stays resilient under host contention, but a high timeout rate means most of the budget produced no useful signal — a saturated machine or a genuinely hanging system — so the runner surfaces it rather than passing silently.
    package static let timeoutWarningFraction = 0.25
}
