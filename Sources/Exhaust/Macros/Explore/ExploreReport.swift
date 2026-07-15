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

    /// Reports property invocations separated by exploration phase.
    public var invocations: ExploreInvocationCounts

    /// Returns the total number of property invocations across all phases.
    public var propertyInvocations: Int {
        invocations.total
    }

    /// Statistics from the untuned warm-up pass, or `nil` when no warm-up ran (the parallel path skips it, as does a run that exits before sampling).
    ///
    /// When this is `nil`, every direction's ``DirectionCoverage/warmup`` is `nil` as well.
    public var warmup: WarmupStats?

    /// Total wall-clock time, in milliseconds.
    public var totalMilliseconds: Double

    /// How the run terminated.
    public var termination: ExploreTermination
}

/// Counts property invocations in each phase of an `#explore` run.
public struct ExploreInvocationCounts: Sendable, Equatable {
    /// Counts property invocations during untuned warm-up sampling.
    public var warmup: Int

    /// Counts property invocations while replaying configured regression seeds against tuned generators.
    public var regression: Int

    /// Counts property invocations while sampling from direction-tuned generators.
    public var directedSampling: Int

    /// Counts property invocations made by the reducer while testing candidate counterexamples.
    public var reduction: Int

    /// Counts final source-located property invocations used to report assertion-closure failures.
    public var diagnostic: Int

    /// Returns the total number of property invocations across all phases.
    public var total: Int {
        warmup + regression + directedSampling + reduction + diagnostic
    }
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
    /// Every direction received the required number of matching samples.
    case coverageAchieved
    /// The shared directed sampling pool reached zero before every direction received the required number of matching samples.
    case budgetExhausted
}

/// Records coverage statistics for a single declared direction.
public struct DirectionCoverage: Sendable {
    /// The user-provided name for this direction.
    public var name: String

    /// Total samples that matched this direction's predicate across all passes.
    public var hits: Int

    /// Counts samples drawn from this direction's tuned generator. Zero if the direction was covered during warm-up or incidentally.
    public var directedSamplingSamples: Int

    /// Counts matching samples from this direction's tuned generator where the property held.
    public var directedSamplingPasses: Int

    /// Counts matching samples from this direction's tuned generator where the property failed.
    public var directedSamplingFailures: Int

    /// Whether this direction met its quota, fell short, or could not be tuned at all.
    public var outcome: DirectionOutcome

    /// This direction's warm-up results, or `nil` when no warm-up ran.
    public var warmup: DirectionWarmup?

    /// Whether this direction received the required number of matching samples.
    public var isCovered: Bool {
        outcome == .covered
    }

    /// Returns the rule-of-three upper bound on the in-direction failure rate from this direction's tuned generator. Returns `nil` when directed sampling produced no matching, passing samples. Describes the failure rate under the CGS-biased distribution, not the generator's natural distribution.
    public var directedSamplingRuleOfThreeBound: Double? {
        directedSamplingPasses > 0 ? 3.0 / Double(directedSamplingPasses) : nil
    }
}

/// The outcome of a single direction's coverage attempt.
public enum DirectionOutcome: Sendable, Equatable {
    /// The direction received the required number of matching samples.
    case covered
    /// Sampling ran but the required number of matching samples was not reached before the directed sampling budget ran out. The direction may be rare or unreachable under the generator.
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
