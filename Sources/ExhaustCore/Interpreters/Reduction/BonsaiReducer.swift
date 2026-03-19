import Foundation

// MARK: - Configuration

public extension Interpreters {
    /// Configuration for the Bonsai reducer's pass pipeline.
    struct BonsaiReducerConfiguration: Sendable {
        /// Maximum number of outer cycles with no improvement before terminating.
        let maxStalls: Int
        /// Per-strategy probe budgets.
        let probeBudgets: TCRConfiguration.ProbeBudgets
        /// Beam search tuning for aligned deletion.
        let alignedDeletionBeamSearchTuning: TCRConfiguration.AlignedDeletionBeamSearchTuning
        /// When `true`, use ``ReductionMaterializer``-backed decoders that produce
        /// fresh trees with current `validRange` and all branch alternatives.
        let useReductionMaterializer: Bool

        /// When `true`, run a one-shot post-processing pass after reduction stalls that reorders
        /// elements within type-homogeneous sibling groups into natural numeric order.
        public var humanOrderPostProcess: Bool = false

        private init(
            maxStalls: Int,
            probeBudgets: TCRConfiguration.ProbeBudgets,
            alignedDeletionBeamSearchTuning: TCRConfiguration.AlignedDeletionBeamSearchTuning,
            useReductionMaterializer: Bool = true
        ) {
            self.maxStalls = maxStalls
            self.probeBudgets = probeBudgets
            self.alignedDeletionBeamSearchTuning = alignedDeletionBeamSearchTuning
            self.useReductionMaterializer = useReductionMaterializer
        }

        /// Maps a ``TCRConfiguration`` preset to the corresponding configuration.
        init(from config: TCRConfiguration) {
            switch config {
            case .fast: self = Self(
                maxStalls: 1,
                probeBudgets: .fast,
                alignedDeletionBeamSearchTuning: .fast
            )
            case .slow: self = Self(
                maxStalls: 8,
                probeBudgets: .slow,
                alignedDeletionBeamSearchTuning: .slow
            )
            }
        }

        public static let fast = Self(
            maxStalls: 1,
            probeBudgets: .fast,
            alignedDeletionBeamSearchTuning: .fast
        )

        public static let slow = Self(
            maxStalls: 8,
            probeBudgets: .slow,
            alignedDeletionBeamSearchTuning: .slow
        )
    }
}

// MARK: - Entry Point

public extension Interpreters {
    /// Bonsai reducer: iterative tree miniaturization via structured pass pipeline.
    static func bonsaiReduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: BonsaiReducerConfiguration,
        property: (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        try withoutActuallyEscaping(property) { escapingProperty in
            try BonsaiScheduler.run(gen: gen, initialTree: tree, config: config, property: escapingProperty)
        }
    }
}
