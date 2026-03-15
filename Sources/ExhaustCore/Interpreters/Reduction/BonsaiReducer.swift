import Foundation

// MARK: - Reducer Dispatch

public extension Interpreters {
    /// Dispatches to either the Bonsai reducer or the standard reducer based on the `useBonsai` flag.
    static func dispatchReduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: TCRConfiguration,
        useBonsai: Bool,
        hasDynamicRanges: Bool = true,
        property: (Output) -> Bool,
    ) throws -> (ChoiceSequence, Output)? {
        if useBonsai {
            return try bonsaiReduce(
                gen: gen,
                tree: tree,
                config: .init(from: config, hasDynamicRanges: hasDynamicRanges),
                property: property,
            )
        } else {
            return try reduce(gen: gen, tree: tree, config: config, property: property)
        }
    }
}

// MARK: - Configuration

public extension Interpreters {
    /// Configuration for the Bonsai reducer's V-cycle pass pipeline.
    struct BonsaiReducerConfiguration: Sendable {
        /// Maximum number of outer cycles with no improvement before terminating.
        let maxStalls: Int
        /// Window size for cycle detection.
        let recentCycleWindow: Int
        /// Per-strategy probe budgets.
        let probeBudgets: TCRConfiguration.ProbeBudgets
        /// Beam search tuning for aligned deletion.
        let alignedDeletionBeamSearchTuning: TCRConfiguration.AlignedDeletionBeamSearchTuning
        /// Whether the generator has dynamic range dependencies (from `._bind` or `.bind()`).
        ///
        /// When `true`, the covariant sweep re-derives after value changes to refresh
        /// stale `validRange` metadata. When `false`, re-derivation is skipped unless
        /// the tree contains explicit `.bind` nodes.
        let hasDynamicRanges: Bool
        /// When `true`, use ``ReductionMaterializer``-backed decoders that produce
        /// fresh trees with current `validRange` and all branch alternatives.
        let useReductionMaterializer: Bool

        private init(
            maxStalls: Int,
            recentCycleWindow: Int,
            probeBudgets: TCRConfiguration.ProbeBudgets,
            alignedDeletionBeamSearchTuning: TCRConfiguration.AlignedDeletionBeamSearchTuning,
            hasDynamicRanges: Bool,
            useReductionMaterializer: Bool = false,
        ) {
            self.maxStalls = maxStalls
            self.recentCycleWindow = recentCycleWindow
            self.probeBudgets = probeBudgets
            self.alignedDeletionBeamSearchTuning = alignedDeletionBeamSearchTuning
            self.hasDynamicRanges = hasDynamicRanges
            self.useReductionMaterializer = useReductionMaterializer
        }

        /// Maps a ``TCRConfiguration`` preset to the corresponding configuration.
        init(from config: TCRConfiguration, hasDynamicRanges: Bool = true) {
            switch config {
            case .fast:
                self = .fast.withDynamicRanges(hasDynamicRanges)
            case .slow:
                self = .slow.withDynamicRanges(hasDynamicRanges)
            }
        }

        private func withDynamicRanges(_ value: Bool) -> Self {
            Self(
                maxStalls: maxStalls,
                recentCycleWindow: recentCycleWindow,
                probeBudgets: probeBudgets,
                alignedDeletionBeamSearchTuning: alignedDeletionBeamSearchTuning,
                hasDynamicRanges: value,
                useReductionMaterializer: useReductionMaterializer,
            )
        }

        static let fast = Self(
            maxStalls: 3,
            recentCycleWindow: 6,
            probeBudgets: .fast,
            alignedDeletionBeamSearchTuning: .fast,
            hasDynamicRanges: true,
            useReductionMaterializer: true,
        )

        static let slow = Self(
            maxStalls: 8,
            recentCycleWindow: 12,
            probeBudgets: .slow,
            alignedDeletionBeamSearchTuning: .slow,
            hasDynamicRanges: true,
            useReductionMaterializer: true,
        )
    }
}

// MARK: - Entry Point

public extension Interpreters {
    /// Bonsai reducer: iterative tree miniaturization via structured pass pipeline.
    ///
    /// Delegates to ``ReductionScheduler`` for the V-cycle pattern: snip (contravariant sweep, depths max→1), prune (deletion sweep, depths 0→max), train (covariant sweep, depth 0), post-processing merge, and shape (redistribution).
    static func bonsaiReduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: BonsaiReducerConfiguration,
        property: (Output) -> Bool,
    ) throws -> (ChoiceSequence, Output)? {
        try ReductionScheduler.run(gen: gen, initialTree: tree, config: config, property: property)
    }
}
