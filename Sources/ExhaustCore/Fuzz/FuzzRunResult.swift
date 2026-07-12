// The verdict, termination, configuration, and result types of the `time:` exploration loop.

/// The outcome of one property evaluation inside a `time:` run.
///
/// Distinguishes the failure's cheap symptom at evaluation time because the backpressure gate needs it synchronously, before any reduction runs.
package enum FuzzVerdict: Sendable {
    case pass
    case fail(FailureSymptom)

    package var isFailure: Bool {
        switch self {
            case .pass:
                false
            case .fail:
                true
        }
    }
}

/// Why a `time:` run stopped.
package enum FuzzTermination: Equatable, Sendable {
    /// The wall-clock budget elapsed.
    case budgetExhausted
    /// No coverage-novel corpus admission for the plateau window; the unused budget is returned rather than burned.
    case plateau(unusedNanoseconds: UInt64)
    /// The package-visible attempt limit was reached (testing control; no time-based termination fired).
    case attemptLimitReached
    /// Generation failed irrecoverably.
    case generationError(String)
}

/// Configuration for one `time:` run. Package-visible controls beyond the public settings exist for the validation harness (phase skipping, attempt limits).
package struct FuzzRunnerConfiguration {
    /// The wall-clock budget in nanoseconds.
    package var budgetNanoseconds: UInt64
    /// Root seed for all PRNG-driven decisions.
    package var seed: UInt64
    /// Covering-array budget for Phase 1.
    package var screeningBudget: UInt64
    /// Skips Phase 1 so mutation-phase tests are not hostage to screening heuristics.
    package var skipScreening: Bool
    /// Skips Phase 2 (with `skipScreening`, the run starts directly in the mutation phase).
    package var skipSampling: Bool
    /// Hard cap on total attempts across all phases, for deterministic tests. Nil means time-bounded only.
    package var attemptLimit: Int?
    /// Crash-recovery configuration: where checkpoints go and what a crashed predecessor left. Nil disables persistence entirely.
    package var persistence: FuzzPersistenceContext?
    /// Knobs for benchmark-gated mechanisms; see ``FuzzExperiments`` for the seam precedence.
    package var experiments: FuzzExperiments
    /// Concurrency cap for the reduction pool. Nil uses the default (processor-count-derived). Width 1 serializes reductions FIFO without dropping them.
    package var reductionPoolWidth: Int?

    package init(
        budgetNanoseconds: UInt64,
        seed: UInt64,
        screeningBudget: UInt64 = 10000,
        skipScreening: Bool = false,
        skipSampling: Bool = false,
        attemptLimit: Int? = nil,
        persistence: FuzzPersistenceContext? = nil,
        experiments: FuzzExperiments = FuzzExperiments()
    ) {
        self.budgetNanoseconds = budgetNanoseconds
        self.seed = seed
        self.screeningBudget = screeningBudget
        self.skipScreening = skipScreening
        self.skipSampling = skipSampling
        self.attemptLimit = attemptLimit
        self.persistence = persistence
        self.experiments = experiments
    }
}

/// The raw result of a `time:` run, wrapped into the public report by the macro runtime.
package struct FuzzRunResult: Sendable {
    package var clusters: [FaultCluster]
    package var unmatchedUnreducedCounts: [FailureSymptom: Int]
    package var screeningAttempts: Int
    package var samplingAttempts: Int
    package var mutationAttempts: Int
    package var discardedAttempts: Int
    package var corpusEntryCount: Int
    package var mutableTierCount: Int
    package var coveredEdgeCount: Int
    package var instrumentedEdgeCount: Int
    /// Edges hit by exactly one attempt (f₁) and exactly two (f₂), for the STADS estimators.
    package var edgeSingletonCount: Int
    package var edgeDoubletonCount: Int
    package var termination: FuzzTermination
    /// Report-time discrimination results, parallel to `clusters` by position.
    package var clusterDiscriminations: [ClusterDiscrimination]
    package var startNanoseconds: UInt64
    package var elapsedNanoseconds: UInt64
    /// Nanoseconds spent inside the property body across all loop attempts; `elapsedNanoseconds` minus this is framework overhead.
    package var propertyNanoseconds: UInt64
    package var seed: UInt64
    package var reductionsTimedOut: Bool

    package var totalAttempts: Int {
        screeningAttempts + samplingAttempts + mutationAttempts
    }

    package var attemptsPerSecond: Double {
        guard elapsedNanoseconds > 0 else {
            return 0
        }
        return Double(totalAttempts) / (Double(elapsedNanoseconds) / 1_000_000_000)
    }
}
