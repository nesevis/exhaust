// MARK: - Reducer Configuration

public extension Interpreters {
    /// Controls the reducer's pass pipeline: stall budget, beam search tuning, and visualization.
    struct ReducerConfiguration: Sendable {
        /// Maximum number of outer cycles with no improvement before terminating.
        public var maxStalls: Int
        /// Beam search tuning for aligned deletion.
        let alignedDeletionBeamSearchTuning: ReductionBudget.AlignedDeletionBeamSearchTuning
        /// When `true`, prints the choice tree before and after reduction as a bottom-up Unicode visualization.
        public var visualize: Bool = false

        /// Sub-budget for branch simplification within base descent.
        var branchSimplificationBudget: Int = 200

        /// Sub-budget for the structural deletion inner loop within base descent.
        var structuralDeletionBudget: Int = 1200

        /// Sub-budget for joint bind-inner reduction within base descent.
        var bindInnerReductionBudget: Int = 600

        private init(
            maxStalls: Int,
            alignedDeletionBeamSearchTuning: ReductionBudget.AlignedDeletionBeamSearchTuning
        ) {
            self.maxStalls = maxStalls
            self.alignedDeletionBeamSearchTuning = alignedDeletionBeamSearchTuning
        }

        /// Maps a ``ReductionBudget`` preset to the corresponding configuration.
        public init(from config: ReductionBudget) {
            switch config {
            case .fast:
                self = Self(
                    maxStalls: 2,
                    alignedDeletionBeamSearchTuning: .fast
                )
            case .slow:
                self = Self(
                    maxStalls: 8,
                    alignedDeletionBeamSearchTuning: .slow
                )
            }
        }

        /// Preset for fast reduction with low stall tolerance.
        public static let fast = Self(
            maxStalls: 2,
            alignedDeletionBeamSearchTuning: .fast
        )

        /// Preset for thorough reduction with higher stall tolerance.
        public static let slow = Self(
            maxStalls: 8,
            alignedDeletionBeamSearchTuning: .slow
        )
    }
}
