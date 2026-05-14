// MARK: - Reducer Configuration

package extension Interpreters {
    /// Controls the ChoiceGraph reducer's pass pipeline: stall budget, scope scheduling, and visualization.
    struct ReducerConfiguration: Sendable {
        /// Maximum number of outer cycles with no improvement before terminating.
        public let maxStalls: Int

        /// When `true`, prints the choice tree before and after reduction as a bottom-up Unicode visualization.
        public var visualize: Bool = false

        /// Tuning constants for the scheduler's internal heuristics.
        public let tuning: SchedulerTuning = .init()

        /// Creates a configuration with the given stall budget.
        public init(
            maxStalls: Int
        ) {
            self.maxStalls = maxStalls
        }
    }
}

// MARK: - Scheduler Tuning

/// Empirically-tuned constants that control the scheduler's internal heuristics.
///
/// Grouped here so that performance-sensitive values have a single location rather than being scattered across scheduler, gate, and classification files. Tests can override individual values to verify budget-sensitive behavior.
package struct SchedulerTuning: Sendable {
    /// Maximum upstream probes per bind site before exponential decay kicks in.
    public var boundValueBaseBudget: Int = 15

    /// Maximum materializations the relax round will attempt before giving up.
    public var relaxMaterializationBudget: Int = 10

    /// Half-width of the bit-pattern window used by bind classification endpoint probing. Unsigned tags probe `0 ... windowRadius`; signed tags probe `simplest ± windowRadius`.
    public var classificationWindowRadius: UInt64 = 10_000

    /// Maximum index distance between source and sink in pairwise exchange operations (redistribution pairs, lockstep suffix windows, type-compatibility edges). Caps O(n²) pair enumeration to O(n × maxPairLookahead) for large homogeneous sequences.
    public static let maxPairLookahead: Int = 50
}
