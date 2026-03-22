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

        /// When `true`, prints the choice tree before and after reduction as a bottom-up Unicode visualization.
        public var visualize: Bool = false

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
    ///
    /// Prefer the overload that accepts a pre-materialized `output` to avoid
    /// a redundant materialization at the entry point.
    static func bonsaiReduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        output: Output,
        config: BonsaiReducerConfiguration,
        humanOrderPostProcess: Bool = false,
        visualize: Bool = false,
        property: (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        var bonsaiConfig = config
        bonsaiConfig.humanOrderPostProcess = humanOrderPostProcess
        bonsaiConfig.visualize = visualize

        if visualize {
            print("── Before reduction ──")
            print(tree.visualization(width: 100))
        }

        let result = try withoutActuallyEscaping(property) { escapingProperty in
            try BonsaiScheduler.run(
                gen: gen,
                initialTree: tree,
                initialOutput: output,
                config: bonsaiConfig,
                property: escapingProperty
            )
        }

        if visualize, let (resultSequence, _) = result {
            let resultTree = ReductionMaterializer.materialize(
                gen,
                prefix: resultSequence,
                mode: .exact,
                fallbackTree: tree
            )
            if case let .success(_, resultChoiceTree, _) = resultTree {
                print("── After reduction ──")
                print(resultChoiceTree.visualization(width: 100))
            }
        }

        return result
    }

    /// Convenience overload that materializes the output from the tree.
    ///
    /// Use when the caller does not already have the generated value.
    static func bonsaiReduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: BonsaiReducerConfiguration,
        property: (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        let prefix = ChoiceSequence.flatten(tree)
        guard case let .success(output, _, _) = ReductionMaterializer.materialize(
            gen, prefix: prefix, mode: .exact, fallbackTree: tree
        ) else {
            return nil
        }
        return try bonsaiReduce(
            gen: gen,
            tree: tree,
            output: output,
            config: config,
            property: property
        )
    }
}
