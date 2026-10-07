// MARK: - Reducer Configuration

/// Wraps one reduction probe's property invocation, receiving the candidate sequence that probe is testing.
///
/// The reducer drives the property at candidates its host never produced, so a host that wants to observe each invocation (mark it in flight, time it, log it) cannot identify the probe from outside; the sequence is how the wrapper knows which one it is around.
package typealias ProbeWrapper = @Sendable (ChoiceSequence, () -> Bool) -> Bool

package extension Interpreters {
    /// Controls the ChoiceGraph reducer's pass pipeline: stall budget, scope scheduling, and visualization.
    struct ReducerConfiguration: Sendable {
        /// Maximum number of outer cycles with no improvement before terminating.
        package let maxStalls: Int

        /// Cooperative elapsed-time budget for reduction search, in nanoseconds. Checked between machine and probe steps, including post-cycle search passes. In-flight materializations and property invocations complete before search stops. The enabled final numeric reorder pass still runs to completion after expiry, so its materializations and property calls can exceed this budget. Zero means no limit.
        package var wallClockDeadlineNanoseconds: UInt64

        /// Restricts dispatch, post-cycle probes, and excursion exploitation to the named encoders. Nil enables all encoders; an empty set disables every probe. Branch pivots, including improving fills and excursion perturbations, use ``EncoderName/branchPivot``; subtree substitutions and descendant promotions use ``EncoderName/substitution``. Use this to stage reduction in multiple passes (for example, structural-only followed by value-only).
        package let enabledEncoders: Set<EncoderName>?

        /// When `true`, prints the choice tree before and after reduction as a bottom-up Unicode visualization.
        package var visualize: Bool = false

        /// Tuning constants for the scheduler's internal heuristics.
        package let tuning: SchedulerTuning

        /// Wraps every probe's property invocation, receiving the candidate sequence that probe is testing.
        ///
        /// Nil for a host that does not observe individual probes, which is the default. The one shipping client is the fuzz loop's crash breadcrumb, which marks the probe's own sequence as in flight so an abnormal termination names it rather than the last search candidate.
        package var probeWrapper: ProbeWrapper?

        /// Creates a configuration with the given stall budget and optional wall-clock deadline. Temporarily excludes ``EncoderName/pairwiseNumericSearch`` by default while staged joint search is evaluated. An explicit encoder set can enable pairwise search for A/B comparisons; nil enables every encoder.
        package init(
            maxStalls: Int,
            wallClockDeadlineNanoseconds: UInt64 = 0,
            enabledEncoders: Set<EncoderName>? = Set(EncoderName.allCases).subtracting([.pairwiseNumericSearch]),
            tuning: SchedulerTuning = .init(),
            probeWrapper: ProbeWrapper? = nil
        ) {
            self.maxStalls = maxStalls
            self.wallClockDeadlineNanoseconds = wallClockDeadlineNanoseconds
            self.enabledEncoders = enabledEncoders
            self.tuning = tuning
            self.probeWrapper = probeWrapper
        }
    }
}

// MARK: - Scheduler Tuning

/// Controls the scheduler's internal heuristics and bounded search policies.
///
/// Grouped here so that performance-sensitive values have a single location rather than being scattered across scheduler, gate, and classification files. Tests can override individual values to verify budget-sensitive behavior.
package struct SchedulerTuning: Sendable {
    /// Maximum upstream probes per bind site before exponential decay kicks in.
    public var boundValueBaseBudget: Int

    /// Maximum excursion materializations per relax round. Zero disables excursions.
    public var relaxMaterializationBudget: Int

    /// Maximum improving pivot probes per relax round. Separate from ``relaxMaterializationBudget`` so that spending it never changes which excursions a round reaches. Zero disables the phase.
    public var relaxImprovingProbeBudget: Int

    /// Maximum probes per checkpoint for the original two-way ``EncoderName/pairwiseNumericSearch`` fallback. Independent of the staged joint budget. Zero disables pairwise search.
    public var pairwiseNumericProbeBudget: Int

    /// Maximum probes per checkpoint for ``EncoderName/stagedJointSearch``, shared by its sequential two-, three-, and four-way stages. Passing probes use one flat materialization; a surviving failure also rebuilds the tree before acceptance. Zero disables staged joint search.
    public var stagedJointProbeBudget: Int

    /// Maximum estimated candidate combinations retained for three-way search after two-way search stalls and at least three nontrivial leaves have stalled. Work sums each group's sampled grid, including compensating increases, plus every ratio-preserving proposal outside that grid. Ranked groups are retained only while their total fits; residual magnitude affects priority rather than eligibility. The default is a starting threshold for calibration. Zero disables this stage and four-way escalation.
    public var threeWayNumericWorkLimit: Int

    /// Maximum estimated candidate combinations retained for four-way search after three-way search stalls and at least four nontrivial leaves have stalled. Uses the same sampled-grid estimate as ``threeWayNumericWorkLimit``. The default is a starting threshold for calibration. Zero disables four-way escalation.
    public var fourWayNumericWorkLimit: Int

    /// Maximum higher-order groups scored across both escalation stages at a checkpoint. Discovery stops at this count before retaining the best scope, so discarded groups cannot cause unbounded preparation.
    public var numericJointGroupCalculationLimit: Int

    /// Maximum ranked groups retained in each higher-order scope.
    public var numericJointScopeLimit: Int

    /// Half-width of the bit-pattern window used by bind classification endpoint probing. Unsigned tags probe `0 ... windowRadius`; signed tags probe `simplest ± windowRadius`.
    public var classificationWindowRadius: UInt64

    /// Maximum probes a bound value composition may emit on a bind fingerprint's first dispatch of the run. Zero means uncapped. Workloads where composition earns acceptances do so with one lift and a handful of probes, while a fruitless first dispatch runs to its full covering enumeration before the gate can blacklist the bind. This cap bounds that classification cost without touching post-acceptance dispatches, which run uncapped because acceptance clears the fingerprint's outcome history. The default of 16 is 8× the accepting spend measured across the benchmark suite (~2 probes), where it cut the worst measured waste by 91% with byte-identical counters and counterexamples everywhere else.
    public var composedFirstDispatchProbeCap: Int

    /// Consecutive fully-rejected migration passes after which migration transformations are skipped for the rest of the run. Zero means never demote. On workloads where migration is productive it accepts on every dispatch, all in the first cycle, so the trigger is unreachable there; on workloads where it never accepts, each fruitless dispatch costs one materialization per pass until demotion fires. An acceptance resets the consecutive count. The default of 3 lost no acceptances anywhere on the benchmark suite: counterexamples and all non-migration counters were byte-identical, with migration spend down roughly 60% on the workloads where it never accepts.
    public var migrationDemotionThreshold: Int

    /// Maximum index distance between source and sink in pairwise operations (type-compatibility edges, lockstep suffix windows). Caps O(n²) pair enumeration to O(n × maxPairLookahead) for large groups.
    public static let maxPairLookahead: Int = 50

    package init(
        boundValueBaseBudget: Int = 15,
        relaxMaterializationBudget: Int = 10,
        relaxImprovingProbeBudget: Int = 2,
        pairwiseNumericProbeBudget: Int = 512,
        stagedJointProbeBudget: Int = 512,
        threeWayNumericWorkLimit: Int = 4096,
        fourWayNumericWorkLimit: Int = 1024,
        numericJointGroupCalculationLimit: Int = 512,
        numericJointScopeLimit: Int = 30,
        classificationWindowRadius: UInt64 = 10000,
        composedFirstDispatchProbeCap: Int = 16,
        migrationDemotionThreshold: Int = 3
    ) {
        self.boundValueBaseBudget = boundValueBaseBudget
        self.relaxMaterializationBudget = relaxMaterializationBudget
        self.relaxImprovingProbeBudget = relaxImprovingProbeBudget
        self.pairwiseNumericProbeBudget = pairwiseNumericProbeBudget
        self.stagedJointProbeBudget = stagedJointProbeBudget
        self.threeWayNumericWorkLimit = threeWayNumericWorkLimit
        self.fourWayNumericWorkLimit = fourWayNumericWorkLimit
        self.numericJointGroupCalculationLimit = numericJointGroupCalculationLimit
        self.numericJointScopeLimit = numericJointScopeLimit
        self.classificationWindowRadius = classificationWindowRadius
        self.composedFirstDispatchProbeCap = composedFirstDispatchProbeCap
        self.migrationDemotionThreshold = migrationDemotionThreshold
    }
}
