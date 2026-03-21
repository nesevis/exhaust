import Foundation

// MARK: - Configuration

public extension Interpreters {
    /// Configuration for the Bonsai reducer's pass pipeline.
    struct BonsaiReducerConfiguration: Sendable {
        /// Maximum number of outer cycles with no improvement before terminating.
        let maxStalls: Int
        /// Beam search tuning for aligned deletion.
        let alignedDeletionBeamSearchTuning: ReductionBudget.AlignedDeletionBeamSearchTuning
        /// When `true`, run a one-shot post-processing pass after reduction stalls that reorders
        /// elements within type-homogeneous sibling groups into natural numeric order.
        public var humanOrderPostProcess: Bool = false

        private init(
            maxStalls: Int,
            alignedDeletionBeamSearchTuning: ReductionBudget.AlignedDeletionBeamSearchTuning
        ) {
            self.maxStalls = maxStalls
            self.alignedDeletionBeamSearchTuning = alignedDeletionBeamSearchTuning
        }

        /// Maps a ``ReductionBudget`` preset to the corresponding configuration.
        init(from config: ReductionBudget) {
            switch config {
            case .fast: self = Self(
                    maxStalls: 1,
                    alignedDeletionBeamSearchTuning: .fast
                )
            case .slow: self = Self(
                    maxStalls: 8,
                    alignedDeletionBeamSearchTuning: .slow
                )
            }
        }

        public static let fast = Self(
            maxStalls: 1,
            alignedDeletionBeamSearchTuning: .fast
        )

        public static let slow = Self(
            maxStalls: 8,
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
