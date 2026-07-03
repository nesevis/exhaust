import ExhaustCore

/// Captures results from a single `#explore` invocation.
///
/// Contains the counterexample (if any), per-direction coverage statistics, and the co-occurrence matrix for cross-direction analysis.
public struct ExploreReport<Output> {
    /// The reduced counterexample if the property failed, or `nil` if all directions were covered without a failure.
    public var result: Output?

    /// The PRNG seed used for this exploration run.
    public var seed: UInt64

    /// Per-direction coverage statistics, in declaration order.
    public var directionCoverage: [DirectionCoverage]

    /// Cross-direction sample co-occurrence counts.
    public var coOccurrence: CoOccurrenceMatrix

    /// The direction membership set of the counterexample, if a failure was found. Each index corresponds to a direction in `directionCoverage`.
    public var counterexampleDirections: [Int]

    /// Total property invocations across warm-up and all tuning passes.
    public var propertyInvocations: Int

    /// Statistics from the untuned warm-up pass, or `nil` when no warm-up ran (the parallel path skips it, as does a run that exits before sampling).
    ///
    /// When this is `nil`, every direction's ``DirectionCoverage/warmup`` is `nil` as well.
    public var warmup: WarmupStats?

    /// Total wall-clock time, in milliseconds.
    public var totalMilliseconds: Double

    /// How the run terminated.
    public var termination: ExploreTermination
}

/// Statistics from the untuned warm-up pass of a sequential `#explore` run.
public struct WarmupStats: Sendable {
    /// Total samples drawn during the warm-up pass. The samples are identically distributed, so per-direction rates computed against this denominator are unbiased.
    public var samples: Int
}

/// Describes how an `#explore` run terminated.
public enum ExploreTermination: Sendable {
    /// The property failed on a sample. The counterexample is available in ``ExploreReport/result``.
    case propertyFailed
    /// Every direction accumulated at least K matching samples.
    case coverageAchieved
    /// The shared attempt pool reached zero before all directions filled their K-hit quotas.
    case budgetExhausted
}

/// Records coverage statistics for a single declared direction.
public struct DirectionCoverage: Sendable {
    /// The user-provided name for this direction.
    public var name: String

    /// Total samples that matched this direction's predicate across all passes.
    public var hits: Int

    /// Total samples drawn during this direction's own tuning pass. Zero if the direction was covered during warm-up or incidentally.
    public var tuningPassSamples: Int

    /// Samples from this direction's tuning pass where the property held.
    public var tuningPassPasses: Int

    /// Samples from this direction's tuning pass where the property failed.
    public var tuningPassFailures: Int

    /// Whether this direction met its quota, fell short, or could not be tuned at all.
    public var outcome: DirectionOutcome

    /// This direction's warm-up results, or `nil` when no warm-up ran.
    public var warmup: DirectionWarmup?

    /// Whether this direction achieved its K-hit quota.
    public var isCovered: Bool {
        outcome == .covered
    }

    /// Rule-of-three upper bound on the in-direction failure rate from this direction's own tuning pass. Nil when the tuning pass produced no passing samples. Describes the failure rate under the CGS-biased distribution, not the generator's natural distribution.
    public var tuningPassRuleOfThreeBound: Double? {
        tuningPassPasses > 0 ? 3.0 / Double(tuningPassPasses) : nil
    }
}

/// The outcome of a single direction's coverage attempt.
public enum DirectionOutcome: Sendable, Equatable {
    /// The direction accumulated its K-hit quota.
    case covered
    /// Sampling ran but the quota was not met before the attempt budget ran out. The direction may be rare or unreachable under the generator.
    case uncovered
    /// CGS tuning for this direction failed before any tuned sampling could run. The direction may still show incidental hits from other passes. Only produced by the sequential path; the parallel path surfaces tuning failures as thrown errors.
    case tuningFailed(String)
}

/// A single direction's results from the warm-up pass.
public struct DirectionWarmup: Sendable {
    /// Samples that matched this direction during warm-up.
    public var hits: Int

    /// Rule-of-three upper bound on the in-direction failure rate. Nil when `hits` is zero. Based on identically distributed samples, so it describes the generator's natural distribution.
    public var ruleOfThreeBound: Double? {
        hits > 0 ? 3.0 / Double(hits) : nil
    }
}
