// MARK: - Reducer Configuration

package extension Interpreters {
    /// Controls the ChoiceGraph reducer's pass pipeline: stall budget, scope scheduling, and visualization.
    struct ReducerConfiguration: Sendable {
        /// Maximum number of outer cycles with no improvement before terminating.
        package let maxStalls: Int

        /// Wall-clock deadline for the reduction phase, in nanoseconds. The machine checks this after each decode step and terminates early when exceeded. Zero means no limit.
        package let wallClockDeadlineNanoseconds: UInt64

        /// When non-nil, only encoders whose name is in this set are dispatched. Transformations targeting other encoders are skipped. Use this to stage reduction in multiple passes (for example, structural-only followed by value-only).
        package let enabledEncoders: Set<EncoderName>?

        /// When `true`, prints the choice tree before and after reduction as a bottom-up Unicode visualization.
        package var visualize: Bool = false

        /// Tuning constants for the scheduler's internal heuristics.
        package let tuning: SchedulerTuning

        /// Creates a configuration with the given stall budget and optional wall-clock deadline.
        package init(
            maxStalls: Int,
            wallClockDeadlineNanoseconds: UInt64 = 0,
            enabledEncoders: Set<EncoderName>? = nil,
            tuning: SchedulerTuning = .init()
        ) {
            self.maxStalls = maxStalls
            self.wallClockDeadlineNanoseconds = wallClockDeadlineNanoseconds
            self.enabledEncoders = enabledEncoders
            self.tuning = tuning
        }
    }
}

// MARK: - Scheduler Tuning

/// Empirically-tuned constants that control the scheduler's internal heuristics.
///
/// Grouped here so that performance-sensitive values have a single location rather than being scattered across scheduler, gate, and classification files. Tests can override individual values to verify budget-sensitive behavior.
package struct SchedulerTuning: Sendable {
    /// Maximum upstream probes per bind site before exponential decay kicks in.
    public var boundValueBaseBudget: Int

    /// Maximum materializations the relax round will attempt before giving up. Set to 0 to disable the relax round entirely.
    public var relaxMaterializationBudget: Int

    /// Half-width of the bit-pattern window used by bind classification endpoint probing. Unsigned tags probe `0 ... windowRadius`; signed tags probe `simplest ± windowRadius`.
    public var classificationWindowRadius: UInt64

    /// Maximum probes a bound value composition may emit on a bind fingerprint's first dispatch of the run. Zero means uncapped. Workloads where composition earns acceptances do so with one lift and a handful of probes, while a fruitless first dispatch runs to its full covering enumeration before the gate can blacklist the bind — this cap bounds that classification cost without touching post-acceptance dispatches, which run uncapped because acceptance clears the fingerprint's outcome history. The default of 16 is 8× the accepting spend measured across the ECOOP suite (~2 probes) and cut BinaryHeap's composed waste from 93 to 8.4 probes per seed with byte-identical counters and counterexamples everywhere else (A/B gate, 2026-07-06).
    public var composedFirstDispatchProbeCap: Int

    /// Maximum index distance between source and sink in pairwise operations (type-compatibility edges, lockstep suffix windows). Caps O(n²) pair enumeration to O(n × maxPairLookahead) for large groups.
    public static let maxPairLookahead: Int = 50

    package init(
        boundValueBaseBudget: Int = 15,
        relaxMaterializationBudget: Int = 10,
        classificationWindowRadius: UInt64 = 10000,
        composedFirstDispatchProbeCap: Int = 16
    ) {
        self.boundValueBaseBudget = boundValueBaseBudget
        self.relaxMaterializationBudget = relaxMaterializationBudget
        self.classificationWindowRadius = classificationWindowRadius
        self.composedFirstDispatchProbeCap = composedFirstDispatchProbeCap
    }
}
