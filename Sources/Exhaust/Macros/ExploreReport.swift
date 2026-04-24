import ExhaustCore

/// Results from a single `#explore` invocation.
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

    /// Total samples drawn during the warm-up pass.
    public var warmupSamples: Int

    /// Total wall-clock time, in milliseconds.
    public var totalMilliseconds: Double

    /// How the run terminated.
    public var termination: ExploreTermination
}

/// How an `#explore` run terminated.
public enum ExploreTermination: Sendable {
    /// The property failed on a sample. The counterexample is available in ``ExploreReport/result``.
    case propertyFailed
    /// Every direction accumulated at least K matching samples.
    case coverageAchieved
    /// The shared attempt pool reached zero before all directions filled their K-hit quotas.
    case budgetExhausted
}

/// Coverage statistics for a single declared direction.
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

    /// Hits accumulated during the warm-up pass (identically distributed, valid for rule-of-three bounds).
    public var warmupHits: Int

    /// Whether this direction achieved its K-hit quota.
    public var isCovered: Bool

    /// Rule-of-three upper bound on the in-direction failure rate from the warm-up pass. Valid only when `warmupHits > 0` and based on identically distributed samples.
    public var warmupRuleOfThreeBound: Double?

    /// Rule-of-three upper bound on the in-direction failure rate from this direction's own tuning pass. Valid but describes the failure rate under the CGS-biased distribution, not the generator's natural distribution.
    public var tuningPassRuleOfThreeBound: Double?
}
