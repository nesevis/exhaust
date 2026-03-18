import Foundation

// MARK: - Configuration

/// Selects which scheduler orchestrates the reduction pipeline.
public enum ReducerSchedulerChoice: Sendable {
    /// V-cycle with five interleaved legs iterated by bind depth.
    case vCycle
    /// Two-phase pipeline: structural minimization with restart-on-success, then DAG-guided value minimization.
    case principled
}

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
        /// Which scheduler to use for the reduction pipeline.
        let scheduler: ReducerSchedulerChoice

        /// When `true`, run a one-shot post-processing pass after V-cycle stalls that reorders
        /// elements within type-homogeneous sibling groups into natural numeric order.
        public var humanOrderPostProcess: Bool = false

        private init(
            maxStalls: Int,
            probeBudgets: TCRConfiguration.ProbeBudgets,
            alignedDeletionBeamSearchTuning: TCRConfiguration.AlignedDeletionBeamSearchTuning,
            useReductionMaterializer: Bool = true,
            scheduler: ReducerSchedulerChoice = .principled
        ) {
            self.maxStalls = maxStalls
            self.probeBudgets = probeBudgets
            self.alignedDeletionBeamSearchTuning = alignedDeletionBeamSearchTuning
            self.useReductionMaterializer = useReductionMaterializer
            self.scheduler = scheduler
        }

        /// Maps a ``TCRConfiguration`` preset to the corresponding configuration using the principled scheduler.
        init(from config: TCRConfiguration) {
            self.init(from: config, scheduler: .principled)
        }

        /// Maps a ``TCRConfiguration`` preset to the corresponding configuration with a specific scheduler.
        init(from config: TCRConfiguration, scheduler: ReducerSchedulerChoice) {
            switch config {
            case .fast: self = Self(
                maxStalls: 1,
                probeBudgets: .fast,
                alignedDeletionBeamSearchTuning: .fast,
                scheduler: scheduler
            )
            case .slow: self = Self(
                maxStalls: 8,
                probeBudgets: .slow,
                alignedDeletionBeamSearchTuning: .slow,
                scheduler: scheduler
            )
            }
        }

        public static let fast = Self(
            maxStalls: 1,
            probeBudgets: .fast,
            alignedDeletionBeamSearchTuning: .fast,
            scheduler: .principled
        )

        public static let slow = Self(
            maxStalls: 8,
            probeBudgets: .slow,
            alignedDeletionBeamSearchTuning: .slow,
            scheduler: .principled
        )
    }
}

// MARK: - Entry Point

public extension Interpreters {
    /// Bonsai reducer: iterative tree miniaturization via structured pass pipeline.
    ///
    /// Delegates to ``ReductionScheduler`` or ``PrincipledScheduler`` depending on the configuration's ``BonsaiReducerConfiguration/scheduler`` choice.
    static func bonsaiReduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: BonsaiReducerConfiguration,
        property: (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        try withoutActuallyEscaping(property) { escapingProperty in
            switch config.scheduler {
            case .vCycle:
                try ReductionScheduler.run(gen: gen, initialTree: tree, config: config, property: escapingProperty)
            case .principled:
                try PrincipledScheduler.run(gen: gen, initialTree: tree, config: config, property: escapingProperty)
            }
        }
    }
}
