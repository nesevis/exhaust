// The verdict, termination, configuration, and result types of the `time:` exploration loop.

/// The outcome of one property evaluation inside a `time:` run.
///
/// Distinguishes the failure's cheap symptom at evaluation time because the backpressure gate needs it synchronously, before any reduction runs.
package enum FuzzVerdict: Sendable {
    case pass
    case fail(FailureSymptom)
    /// The property declined to judge the input (a skip error): the precondition was not met. Not a failure and not evidence of passing; the corpus keeps coverage-novel discards as low-energy mutation parents, because a mutation of a near-miss is the likeliest route to a valid input on a sparse precondition.
    case discard

    package var isFailure: Bool {
        switch self {
            case .pass, .discard:
                false
            case .fail:
                true
        }
    }

    package var isDiscard: Bool {
        if case .discard = self {
            return true
        }
        return false
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
    /// A fault clustered and ``FuzzRunnerConfiguration/stopOnFirstFault`` was set.
    case firstFaultFound
    /// Attempts ran against an instrumented build and recorded no edges at all, so the search has no signal to follow. Distinct from a build with no instrumentation: the counters exist, the run simply cannot see them from the lane it bound.
    case coverageUnreachable
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
    /// Consecutive samples without a corpus admission before Phase 2 hands over to the mutation phase. Spec runs lower this because one spec attempt costs orders of magnitude more than one value attempt.
    package var samplingPlateauWindow: Int
    /// Skips Phase 1 so mutation-phase tests are not hostage to screening heuristics.
    package var skipScreening: Bool
    /// Skips Phase 2 (with `skipScreening`, the run starts directly in the mutation phase).
    package var skipSampling: Bool
    /// Skips Phase 3, so the run is screening and sampling only.
    ///
    /// Also disables the plateau window and the sampling time backstop: both exist solely to decide when to hand over to mutation, and with no phase to hand over to they would end the run early instead. Sampling then runs until the budget or the attempt limit stops it, which is what a non-guided control arm needs.
    package var skipMutation: Bool = false
    /// Ends the run early once the STADS discovery-probability estimate falls below ``FuzzTunables/saturationDiscoveryProbability``, returning the unused budget. Set by the public `.stopWhenSaturated` setting.
    ///
    /// Off by default, so a run spends the budget it was given. Coverage saturation is not fault exhaustion: measurement on the Etna IFC protocol found roughly a fifth of all detections arriving after the search stopped reaching new edges, which is why this cannot be the default.
    package var stopWhenSaturated: Bool = false
    /// Attempts before the first saturation check, and the floor on sample size the estimate needs to mean anything. Defaults to ``FuzzTunables/saturationMinimumAttempts``; lowered by tests that need the path on a small sample, and the field a calibration harness varies.
    package var saturationMinimumAttempts: Int = FuzzTunables.saturationMinimumAttempts
    /// Attempts between saturation checks once the minimum is reached. Defaults to ``FuzzTunables/saturationCheckInterval``.
    package var saturationCheckInterval: Int = FuzzTunables.saturationCheckInterval
    /// Hard cap on total attempts across all phases, for deterministic tests. Nil means time-bounded only.
    package var attemptLimit: Int?
    /// Ends the run as soon as one fault clusters, rather than continuing to search. Set by the public `.failFast` setting, and by measurement harnesses.
    ///
    /// The measurement question "how much work did finding this cost?" is answered by the attempt at which the first fault landed, and a run that keeps going past it reports a total dominated by whatever the stopping rule does afterwards. Off by default: a normal campaign wants every distinct fault, not the first.
    package var stopOnFirstFault: Bool = false
    /// Crash-recovery configuration: where checkpoints go and what a crashed predecessor left. Nil disables persistence entirely.
    package var persistence: FuzzPersistenceContext?
    /// Knobs for benchmark-gated mechanisms; see ``FuzzExperiments`` for more.
    package var experiments: FuzzExperiments
    /// Called once per attempt with its phase and the edges that attempt hit. Nil in production runs; coverage-harvest tooling uses it to build a first-hit timeline without re-reading the counter regions.
    package var onAttempt: ((FuzzPhase, [(edge: Int, hitCount: UInt8)]) -> Void)?

    package init(
        budgetNanoseconds: UInt64,
        seed: UInt64,
        screeningBudget: UInt64 = 1000,
        samplingPlateauWindow: Int = FuzzTunables.samplingPlateauWindow,
        skipScreening: Bool = false,
        skipSampling: Bool = false,
        skipMutation: Bool = false,
        attemptLimit: Int? = nil,
        persistence: FuzzPersistenceContext? = nil,
        experiments: FuzzExperiments = FuzzExperiments(),
        onAttempt: ((FuzzPhase, [(edge: Int, hitCount: UInt8)]) -> Void)? = nil
    ) {
        self.budgetNanoseconds = budgetNanoseconds
        self.seed = seed
        self.screeningBudget = screeningBudget
        self.samplingPlateauWindow = samplingPlateauWindow
        self.skipScreening = skipScreening
        self.skipSampling = skipSampling
        self.skipMutation = skipMutation
        self.attemptLimit = attemptLimit
        self.persistence = persistence
        self.experiments = experiments
        self.onAttempt = onAttempt
    }
}

/// Groups lifecycle accounting for a `time:` run separately from its resulting corpus, coverage, and timing statistics.
package struct FuzzRunCounts: Sendable {
    package var screeningAttempts = 0
    package var samplingAttempts = 0
    package var mutationAttempts = 0
    package var screeningRejectedAttempts = 0
    package var discardedAttempts = 0
    /// Evaluated search cases the property discarded (a skip error). Counted inside `evaluatedSearchCases`, since the property ran.
    package var discardedEvaluations = 0
    package var evaluatedSearchCases = 0
    /// Candidates evaluated inside campaign probe sessions (counted inside `mutationAttempts` too). Zero whenever the `campaignMutation` knob is off or no parent's stall gate opened.
    package var campaignAttempts = 0
    package var pruneInvocations = 0
    package var reductionInvocations = 0
    package var normalizationInvocations = 0
    package var classificationInvocations = 0
    package var recoveryInvocations = 0

    /// Counts candidate opportunities opened across all search phases, including candidates rejected before property entry.
    package var totalAttempts: Int {
        screeningAttempts + samplingAttempts + mutationAttempts
    }

    /// Counts property invocations across search, pruning, reduction, normalization, classification, and recovery.
    package var totalPropertyInvocations: Int {
        evaluatedSearchCases
            + pruneInvocations
            + reductionInvocations
            + normalizationInvocations
            + classificationInvocations
            + recoveryInvocations
    }
}

/// Holds non-overlapping wall-clock buckets whose sum is the runner's elapsed time once residual setup and finalization work is derived.
package struct FuzzRunTiming: Sendable {
    package var propertyNanoseconds: UInt64 = 0
    package var screeningOverheadNanoseconds: UInt64 = 0
    package var samplingOverheadNanoseconds: UInt64 = 0
    package var mutationOverheadNanoseconds: UInt64 = 0
    package var reductionNanoseconds: UInt64 = 0

    /// Returns elapsed time not attributed to a property invocation, search phase, or reduction, clamping inconsistent input rather than underflowing.
    package func otherNanoseconds(totalNanoseconds: UInt64) -> UInt64 {
        let accountedNanoseconds = propertyNanoseconds
            + screeningOverheadNanoseconds
            + samplingOverheadNanoseconds
            + mutationOverheadNanoseconds
            + reductionNanoseconds
        return totalNanoseconds - min(accountedNanoseconds, totalNanoseconds)
    }
}

/// The raw result of a `time:` run, wrapped into the public report by the macro runtime.
package struct FuzzRunResult: Sendable {
    package var clusters: [FaultCluster]
    package var unmatchedUnreducedCounts: [FailureSymptom: Int]
    package var counts: FuzzRunCounts
    package var corpusEntryCount: Int
    package var mutableTierCount: Int
    package var coveredEdgeCount: Int
    package var instrumentedEdgeCount: Int
    /// Incidence frequency counts: edges hit by exactly one attempt (Q₁), two (Q₂), three (Q₃), four (Q₄), plus the incidence-matrix sum. Q₃ and Q₄ feed iChao2; the sum denominates the discovery probability.
    package var edgeSingletonCount: Int
    package var edgeDoubletonCount: Int
    package var edgeTripletonCount: Int = 0
    package var edgeQuadrupletonCount: Int = 0
    /// `V`, the incidence-matrix sum: the discovery-probability denominator for incidence data.
    package var incidenceTotal: Int = 0
    package var termination: FuzzTermination
    /// Report-time discrimination results, parallel to `clusters` by position.
    package var clusterDiscriminations: [ClusterDiscrimination]
    package var startNanoseconds: UInt64
    package var elapsedNanoseconds: UInt64
    /// Time from the run's start to its last new edge, or zero if it never covered one.
    ///
    /// The gap between this and `elapsedNanoseconds` is time the run spent covering no new code. It is
    /// not the same question the mutation phase's plateau window asks, which is time since the last
    /// corpus admission — a candidate also enters on a new hit-count bucket for an edge already known.
    package var lastNewEdgeNanoseconds: UInt64 = 0
    /// Attempts evaluated when the first fault clustered, or zero if none did.
    ///
    /// Recorded at the moment of classification rather than interpolated from the clock, because it is the answer to what finding the fault cost and the two diverge once a run keeps searching afterwards.
    package var attemptsAtFirstFault: Int = 0
    package var timing: FuzzRunTiming
    package var seed: UInt64
    /// Instrumented edges that fired during the run on threads the run did not own, so the search never saw them. Zero when the source cannot tell.
    package var offLaneEdgeHits: Int = 0

    /// The elapsed time net of inline reduction — the denominator for throughput and overhead, so a failure-dense run does not read as a slow pipeline.
    package var searchNanoseconds: UInt64 {
        elapsedNanoseconds - min(timing.reductionNanoseconds, elapsedNanoseconds)
    }

    /// Time from the run's start to the last fault cluster that classified as new, or zero if none did.
    package var lastNewClusterNanoseconds: UInt64 {
        let latest = clusters.map { $0.firstSeenNanoseconds }.max() ?? 0
        return latest > startNanoseconds ? latest - startNanoseconds : 0
    }

    /// The share of the run that followed its last discovery, counting new edges and new fault clusters alike.
    ///
    /// Resuming a crashed run backdates the epoch, so a resumed run's discoveries can predate this
    /// process entirely; the clamp keeps the fraction in range rather than reporting the shortfall.
    package var idleFraction: Double {
        guard elapsedNanoseconds > 0 else {
            return 0
        }
        let lastDiscovery = min(max(lastNewEdgeNanoseconds, lastNewClusterNanoseconds), elapsedNanoseconds)
        return Double(elapsedNanoseconds - lastDiscovery) / Double(elapsedNanoseconds)
    }

    package var attemptsPerSecond: Double {
        guard searchNanoseconds > 0 else {
            return 0
        }
        return Double(counts.evaluatedSearchCases) / (Double(searchNanoseconds) / 1_000_000_000)
    }
}
