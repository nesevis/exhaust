// The verdict, termination, configuration, and result types of the `time:` exploration loop.

/// The outcome of one property evaluation inside a `time:` run.
///
/// Distinguishes the failure's cheap symptom at evaluation time because the backpressure gate needs it synchronously, before any reduction runs.
package enum FuzzVerdict: Sendable {
    case pass
    case fail(FailureSymptom)
    /// The property declined to judge the input (a skip error): the precondition was not met. Not a failure and not evidence of passing; the corpus keeps coverage-novel discards as low-energy mutation parents, because a mutation of a near-miss is the likeliest route to a valid input on a sparse precondition.
    case discard
    /// The evaluation did not reach a verdict, so nothing was learned about the input. Distinct from ``discard``, which is a judgement the property made: an inconclusive attempt produced coverage that describes a stalled execution rather than the input's behaviour, so it is counted and then dropped. Offering it would seed the corpus with the shape of a timeout.
    case inconclusive
    /// The evaluation reached no verdict and its work is still running: the property's asynchronous work outlived cancellation and was abandoned. Inconclusive for the input in the same way as ``inconclusive``, and fatal for the run: the escaped work keeps executing the system under test and keeps recording coverage, so every later evaluation would measure some of it. The runner ends the run with ``FuzzTermination/uncontainedAsyncWork`` on seeing it.
    case escaped

    package var isFailure: Bool {
        switch self {
            case .pass, .discard, .inconclusive, .escaped:
                false
            case .fail:
                true
        }
    }

    /// Whether the evaluation reached no verdict, whichever way: ``inconclusive`` or ``escaped``.
    package var isInconclusive: Bool {
        switch self {
            case .inconclusive, .escaped:
                true
            case .pass, .fail, .discard:
                false
        }
    }

    package var isEscaped: Bool {
        if case .escaped = self {
            return true
        }
        return false
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
    /// An attempt's asynchronous work outlived its cancellation drain and was abandoned while still running. The run stops because that work keeps executing the system under test and keeps recording coverage against later attempts, so every attempt after it is measuring something other than its own input.
    case uncontainedAsyncWork
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

    /// Whether the crash breadcrumb stores each candidate's own sequence: on at or above ``FuzzTunables/trapCandidateBudgetFloor``, where a trapping input is worth the per-invocation cost of recording it.
    package var recordsTrapCandidate: Bool {
        budgetNanoseconds >= FuzzTunables.trapCandidateBudgetFloor
    }

    package init(
        budgetNanoseconds: UInt64,
        seed: UInt64,
        screeningBudget: UInt64 = FuzzTunables.screeningBudget,
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

/// Which producer a candidate came from, so a duplicate skip can be charged to the arm that made it.
///
/// The mutation phase runs several producers over the same corpus, and they differ sharply in how often they rebuild something already evaluated. Without this the run reports one aggregate rate, which cannot say whether an arm is worth its attempts.
package enum CandidateOrigin: Int, CaseIterable, Sendable {
    /// A covering array row. Rows are distinct by construction and skip the recent-hash table, so this count is always zero.
    case screeningRow
    /// A fresh interpreter draw: the sampling phase, and the mutation phase's empty-tier fallback.
    case freshSample
    /// An ordinary mutation of a corpus parent.
    case mutationChild
    /// A harvested comparison operand reconstructed into a whole value.
    case reflectionInjection
    /// A harvested operand grafted into one field of a corpus parent.
    case graftInjection
    /// A harvested operand written over tag-compatible entries of a parent's flat sequence.
    case comparandSubstitution
}

/// What became of one candidate opportunity.
package enum FuzzAttemptOutcome: Int, CaseIterable, Sendable {
    /// The property ran and passed.
    case pass = 0
    /// The property ran and failed.
    case fail
    /// The property ran and declined to judge the value (a skip error).
    case discard
    /// The property ran and reached no verdict: a `.tasks` probe that stalled and was cancelled, or one whose work escaped.
    case inconclusive
    /// The materializer rejected the candidate before the property ran: a mutated prefix guided materialization could not complete, a screening row that would not build, or a tree that would not rebuild.
    case rejectedByMaterializer
    /// Skipped before the property ran because the run had recently evaluated the same choice sequence.
    case duplicate

    /// Whether the property ran.
    package var isEvaluated: Bool {
        switch self {
            case .pass, .fail, .discard, .inconclusive:
                true
            case .rejectedByMaterializer, .duplicate:
                false
        }
    }

    package init(_ verdict: FuzzVerdict) {
        self = if verdict.isInconclusive {
            .inconclusive
        } else if verdict.isDiscard {
            .discard
        } else if verdict.isFailure {
            .fail
        } else {
            .pass
        }
    }
}

/// Every mutation candidate's outcome, by the arm that produced it.
///
/// Separate from ``FuzzAttemptLedger`` rather than a fourth dimension of it, because a candidate's arms are a mask and not a single value: one child can carry several operators and each is credited, so the two tables have different row counts for the same run. The reduction phase reports the same shape per encoder, so an arm's discard rate reads the way an encoder's rejection rate does.
///
/// Scoped to candidates that reached the property. A candidate the materializer rejected or the duplicate cache skipped never reaches the crediting site, and its arms are counted in neither table; ``FuzzRunCounts/subscript(duplicateSkipsFor:)`` answers the duplicate question per producer.
package struct MutationArmLedger: Sendable, Equatable {
    private static let outcomeCount = FuzzAttemptOutcome.allCases.count
    private var table: [Int]

    package init() {
        table = Array(repeating: 0, count: MutationArm.allCases.count * Self.outcomeCount)
    }

    package mutating func record(arm: MutationArm, outcome: FuzzAttemptOutcome) {
        table[arm.rawValue * Self.outcomeCount + outcome.rawValue] += 1
    }

    /// Candidates this arm produced that reached the property, whatever the verdict.
    package func count(arm: MutationArm) -> Int {
        let base = arm.rawValue * Self.outcomeCount
        return table[base ..< (base + Self.outcomeCount)].reduce(0, +)
    }

    package func count(arm: MutationArm, outcome: FuzzAttemptOutcome) -> Int {
        table[arm.rawValue * Self.outcomeCount + outcome.rawValue]
    }

    /// Whether any arm produced anything, so a report can omit the section entirely on a run with no mutation phase.
    package var isEmpty: Bool {
        table.allSatisfy { $0 == 0 }
    }
}

/// Every candidate opportunity of a `time:` run, by phase, producer, and outcome.
///
/// One table replaces the per-phase and per-producer tallies the loop used to increment by hand at six different sites. Every candidate carries its phase and origin, so ``FuzzRunner/evaluate(_:)`` and the producers record exactly one outcome per opportunity, and every figure the report prints is a sum over some slice of the table.
package struct FuzzAttemptLedger: Sendable, Equatable {
    private static let originCount = CandidateOrigin.allCases.count
    private static let outcomeCount = FuzzAttemptOutcome.allCases.count
    private static let phaseStride = originCount * outcomeCount

    private var cells = [Int](repeating: 0, count: FuzzPhase.allCases.count * phaseStride)

    package init() {}

    private static func index(_ phase: FuzzPhase, _ origin: CandidateOrigin, _ outcome: FuzzAttemptOutcome) -> Int {
        phase.ordinal * phaseStride + origin.rawValue * outcomeCount + outcome.rawValue
    }

    package mutating func record(_ phase: FuzzPhase, _ origin: CandidateOrigin, _ outcome: FuzzAttemptOutcome) {
        cells[Self.index(phase, origin, outcome)] += 1
    }

    package func count(_ phase: FuzzPhase, _ origin: CandidateOrigin, _ outcome: FuzzAttemptOutcome) -> Int {
        cells[Self.index(phase, origin, outcome)]
    }

    /// Opportunities in one phase, every producer and outcome.
    package func count(phase: FuzzPhase) -> Int {
        let base = phase.ordinal * Self.phaseStride
        return cells[base ..< base + Self.phaseStride].reduce(0, +)
    }

    /// Opportunities from one producer across every phase, or one outcome of that producer's.
    package func count(origin: CandidateOrigin, outcome: FuzzAttemptOutcome? = nil) -> Int {
        var total = 0
        for phase in FuzzPhase.allCases {
            if let outcome {
                total += count(phase, origin, outcome)
            } else {
                for candidateOutcome in FuzzAttemptOutcome.allCases {
                    total += count(phase, origin, candidateOutcome)
                }
            }
        }
        return total
    }

    /// One outcome across every phase and producer.
    package func count(outcome: FuzzAttemptOutcome) -> Int {
        var total = 0
        for phase in FuzzPhase.allCases {
            for origin in CandidateOrigin.allCases {
                total += count(phase, origin, outcome)
            }
        }
        return total
    }

    /// One outcome within one phase.
    package func count(phase: FuzzPhase, outcome: FuzzAttemptOutcome) -> Int {
        var total = 0
        for origin in CandidateOrigin.allCases {
            total += count(phase, origin, outcome)
        }
        return total
    }

    package var total: Int {
        cells.reduce(0, +)
    }
}

/// Counters that describe the machinery rather than the search: read by the attachment renderer, never by the loop.
package struct FuzzDiagnostics: Sendable, Equatable {
    /// Comparand-substitution energy keys seated into a slot another key held, and seatings overall. A high ratio means the energy table is undersized for the run and retirement is being undone by collision.
    package var operandEnergyEvictions = 0
    package var operandEnergySeatings = 0
    package var operandEnergyRetirements = 0
    /// Pruning passes that removed nothing, so the original evaluation stood in for a re-evaluation of the identical sequence.
    package var pruneIdentitySkips = 0

    package init() {}
}

/// Lifecycle accounting for a `time:` run: the attempt table and the property invocations outside it. The named figures are projections of the two, kept so the report and the tests read the same names as before.
package struct FuzzRunCounts: Sendable {
    /// Every candidate opportunity, by phase, producer, and outcome.
    package var attempts = FuzzAttemptLedger()

    /// Property invocations outside search attempts: pruning, reduction, normalization, classification, and recovery. Aggregate counts only; their verdicts are consumed where they happen.
    package var invocations = RunLedger()

    /// Mutation candidates that reached the property, by the arm that produced them and the verdict they reached.
    package var mutationArms = MutationArmLedger()

    package init() {}

    package var screeningAttempts: Int {
        attempts.count(phase: .screening)
    }

    package var samplingAttempts: Int {
        attempts.count(phase: .sampling)
    }

    package var mutationAttempts: Int {
        attempts.count(phase: .mutation)
    }

    /// Screening rows rejected while building or materializing their candidate.
    package var screeningRejectedAttempts: Int {
        attempts.count(phase: .screening, outcome: .rejectedByMaterializer)
    }

    /// Sampling and mutation candidates the materializer rejected before property entry.
    package var discardedAttempts: Int {
        attempts.count(phase: .sampling, outcome: .rejectedByMaterializer)
            + attempts.count(phase: .mutation, outcome: .rejectedByMaterializer)
    }

    /// Evaluated search cases the property discarded (a skip error). Counted inside `evaluatedSearchCases`, since the property ran.
    package var discardedEvaluations: Int {
        attempts.count(outcome: .discard)
    }

    /// Attempts whose evaluation reached no verdict. Counted inside `evaluatedSearchCases`, since the property ran; excluded from the corpus, since nothing was learned about the input.
    package var inconclusiveAttempts: Int {
        attempts.count(outcome: .inconclusive)
    }

    package var evaluatedSearchCases: Int {
        FuzzAttemptOutcome.allCases.reduce(0) { total, outcome in
            outcome.isEvaluated ? total + attempts.count(outcome: outcome) : total
        }
    }

    /// Candidates produced by the three comparison-operand injection paths, each counted inside `mutationAttempts` too. A drawn operand that reconstructs, reflects, or finds no slot is not an attempt. All zero on a build without trace-cmp instrumentation, since the pool never fills.
    package var reflectionInjectionAttempts: Int {
        attempts.count(origin: .reflectionInjection)
    }

    package var graftInjectionAttempts: Int {
        attempts.count(origin: .graftInjection)
    }

    package var comparandSubstitutionAttempts: Int {
        attempts.count(origin: .comparandSubstitution)
    }

    package var pruneInvocations: Int {
        invocations.count(.prune)
    }

    package var reductionInvocations: Int {
        invocations.count(.reduction)
    }

    package var normalizationInvocations: Int {
        invocations.count(.normalization)
    }

    package var classificationInvocations: Int {
        invocations.count(.classification)
    }

    package var recoveryInvocations: Int {
        invocations.count(.recovery)
    }

    /// Search candidates skipped before property entry because the run had recently evaluated the same choice sequence. Counted in the phase's attempt tally, not in `evaluatedSearchCases`.
    package var duplicateCandidatesSkipped: Int {
        attempts.count(outcome: .duplicate)
    }

    /// One producer's duplicate skips, so a duplicate rate can be read per arm: the arm's skips over its attempts.
    package subscript(duplicateSkipsFor origin: CandidateOrigin) -> Int {
        attempts.count(origin: origin, outcome: .duplicate)
    }

    /// Candidate opportunities opened across all search phases, including candidates rejected before property entry.
    package var totalAttempts: Int {
        attempts.total
    }

    /// Property invocations across search, pruning, reduction, normalization, classification, and recovery.
    package var totalPropertyInvocations: Int {
        evaluatedSearchCases + invocations.totalInvocations
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
    package var diagnostics: FuzzDiagnostics
    package var corpusEntryCount: Int
    package var parentCount: Int
    package var instrumentedEdgeCount: Int
    /// The corpus's edge incidence at the end of the run: covered edges and the Q₁ to Q₄ frequency counts that feed the estimators.
    package var incidence: EdgeIncidenceProfile
    /// `V`, the incidence-matrix sum: the discovery-probability denominator for incidence data.
    package var incidenceTotal: Int = 0
    /// Counts conclusive, nonduplicate search cases represented as rows in the incidence matrix.
    package var incidenceSampleCount: Int = 0
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
    /// The parent domain's length and cell distribution at the end of the run.
    package var parentProfile: ParentProfile = .empty

    package var coveredEdgeCount: Int {
        incidence.covered
    }

    package var edgeSingletonCount: Int {
        incidence.singletons
    }

    package var edgeDoubletonCount: Int {
        incidence.doubletons
    }

    package var edgeTripletonCount: Int {
        incidence.tripletons
    }

    package var edgeQuadrupletonCount: Int {
        incidence.quadrupletons
    }

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
