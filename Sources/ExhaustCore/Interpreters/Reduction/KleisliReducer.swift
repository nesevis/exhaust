import Foundation

// MARK: - Reducer Dispatch

public extension Interpreters {
    /// Dispatches to either the Kleisli reducer or the standard reducer based on the `useKleisli` flag.
    static func dispatchReduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: TCRConfiguration,
        useKleisli: Bool,
        property: (Output) -> Bool,
    ) throws -> (ChoiceSequence, Output)? {
        if useKleisli {
            return try kleisliReduce(gen: gen, tree: tree, config: .init(from: config), property: property)
        } else {
            return try reduce(gen: gen, tree: tree, config: config, property: property)
        }
    }
}

// MARK: - Configuration

public extension Interpreters {
    /// Configuration for the V-cycle reducer.
    struct KleisliReducerConfiguration: Sendable {
        /// Maximum number of outer cycles with no improvement before terminating.
        let maxStalls: Int
        /// Window size for cycle detection.
        let recentCycleWindow: Int
        /// Per-strategy probe budgets.
        let probeBudgets: TCRConfiguration.ProbeBudgets
        /// Beam search tuning for aligned deletion.
        let alignedDeletionBeamSearchTuning: TCRConfiguration.AlignedDeletionBeamSearchTuning

        private init(
            maxStalls: Int,
            recentCycleWindow: Int,
            probeBudgets: TCRConfiguration.ProbeBudgets,
            alignedDeletionBeamSearchTuning: TCRConfiguration.AlignedDeletionBeamSearchTuning,
        ) {
            self.maxStalls = maxStalls
            self.recentCycleWindow = recentCycleWindow
            self.probeBudgets = probeBudgets
            self.alignedDeletionBeamSearchTuning = alignedDeletionBeamSearchTuning
        }

        /// Maps a ``TCRConfiguration`` preset to the corresponding configuration.
        init(from config: TCRConfiguration) {
            switch config {
            case .fast:
                self = .fast
            case .slow:
                self = .slow
            }
        }

        static let fast = Self(
            maxStalls: 3,
            recentCycleWindow: 6,
            probeBudgets: .fast,
            alignedDeletionBeamSearchTuning: .fast,
        )

        static let slow = Self(
            maxStalls: 8,
            recentCycleWindow: 12,
            probeBudgets: .slow,
            alignedDeletionBeamSearchTuning: .slow,
        )
    }
}

// MARK: - Entry Point

public extension Interpreters {
    /// V-cycle reducer: multigrid reduction over bind depths.
    ///
    /// Delegates to ``ReductionScheduler`` for the V-cycle pattern:
    /// contravariant sweep (depths max→1), deletion sweep (depths 0→max),
    /// covariant sweep (depth 0), post-processing merge, and redistribution.
    static func kleisliReduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: KleisliReducerConfiguration,
        property: (Output) -> Bool,
    ) throws -> (ChoiceSequence, Output)? {
        try ReductionScheduler.run(gen: gen, initialTree: tree, config: config, property: property)
    }
}
