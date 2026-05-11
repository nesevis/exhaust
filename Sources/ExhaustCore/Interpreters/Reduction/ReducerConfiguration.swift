// MARK: - Reducer Configuration

package extension Interpreters {
    /// Controls the reducer's pass pipeline: stall budget, beam search tuning, and visualization.
    struct ReducerConfiguration: Sendable {
        /// Maximum number of outer cycles with no improvement before terminating.
        public var maxStalls: Int

        /// When `true`, prints the choice tree before and after reduction as a bottom-up Unicode visualization.
        public var visualize: Bool = false

        /// Tuning constants for the scheduler's internal heuristics.
        public var tuning: SchedulerTuning = .init()

        /// Creates a configuration with the given stall budget.
        public init(
            maxStalls: Int
        ) {
            self.maxStalls = maxStalls
        }

        /// Preset for fast reduction with low stall tolerance.
        public static let fast = Self(maxStalls: 2)

        /// Preset for thorough reduction with higher stall tolerance.
        public static let slow = Self(maxStalls: 8)
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
}
