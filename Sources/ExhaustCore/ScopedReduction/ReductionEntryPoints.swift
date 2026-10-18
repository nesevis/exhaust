//
//  ReductionEntryPoints.swift
//  Exhaust
//

// MARK: - Reduction Outcome

/// Describes the result of a reduction pass.
package enum ReductionOutcome<Output> {
    /// Reduction improved the counterexample.
    case reduced(ChoiceSequence, ChoiceTree, Output)

    /// Reduction ran but could not improve the counterexample.
    case unreduced(ChoiceSequence, ChoiceTree, Output)

    /// Reduction could not produce a result (for example, materialization of the input failed).
    case failure

    /// The counterexample and its choice sequence, regardless of whether reduction improved it.
    package var counterexample: (ChoiceSequence, Output)? {
        switch self {
            case let .reduced(sequence, _, output): (sequence, output)
            case let .unreduced(sequence, _, output): (sequence, output)
            case .failure: nil
        }
    }
}

// MARK: - Reduction Entry Points

package extension Interpreters {
    /// Reduces a failing counterexample using the scoped reduction pipeline.
    ///
    /// - Parameters:
    ///   - gen: The generator that produced the counterexample.
    ///   - tree: The choice tree from the failing run.
    ///   - output: The output value from the failing run.
    ///   - config: Reducer configuration (stall budget, and so on).
    ///   - property: The property that fails on the counterexample.
    /// - Returns: A ``ReductionOutcome`` describing whether the counterexample was reduced, unchanged, or could not be processed.
    static func choiceGraphReduce<Output>(
        gen: Generator<Output>,
        tree: ChoiceTree,
        output: Output,
        config: ReducerConfiguration,
        property: (Output) -> Bool
    ) -> ReductionOutcome<Output> {
        reduceChoiceGraph(
            gen: gen,
            tree: tree,
            output: output,
            config: config,
            collectStats: false,
            property: property
        ).outcome
    }

    /// Reduces a failing counterexample using the scoped pipeline and returns accumulated statistics.
    ///
    /// - Returns: A ``ReductionOutcome`` and a ``ReductionStats`` value summarizing encoder probe counts, materialization attempts, and cycle count.
    static func choiceGraphReduceCollectingStats<Output>(
        gen: Generator<Output>,
        tree: ChoiceTree,
        output: Output,
        config: ReducerConfiguration,
        property: (Output) -> Bool
    ) -> (outcome: ReductionOutcome<Output>, stats: ReductionStats) {
        reduceChoiceGraph(
            gen: gen,
            tree: tree,
            output: output,
            config: config,
            collectStats: true,
            property: property
        )
    }

    /// Keeps visualization and property lifetime handling identical for both reduction entry points.
    private static func reduceChoiceGraph<Output>(
        gen: Generator<Output>,
        tree: ChoiceTree,
        output: Output,
        config: ReducerConfiguration,
        collectStats: Bool,
        property: (Output) -> Bool
    ) -> (outcome: ReductionOutcome<Output>, stats: ReductionStats) {
        if config.visualize {
            print("── Before reduction ──")
            print(tree.visualization(width: 100))
        }

        let result = ScopedReductionRunner.reduce(
            generator: gen,
            tree: tree,
            output: output,
            configuration: config,
            collectStats: collectStats,
            property: property
        )

        if config.visualize, let (resultSequence, _) = result.outcome.counterexample {
            let resultTree = Materializer.materialize(
                gen,
                context: .init(
                    prefix: resultSequence,
                    mode: .exact,
                    fallbackTree: tree
                )
            )
            if case let .success(_, resultChoiceTree, _) = resultTree {
                print("── After reduction ──")
                print(resultChoiceTree.visualization(width: 100))
            }
        }

        return result
    }

    /// Convenience overload that materializes the output from the tree before reducing.
    static func choiceGraphReduce<Output>(
        gen: Generator<Output>,
        tree: ChoiceTree,
        config: ReducerConfiguration,
        property: (Output) -> Bool
    ) -> ReductionOutcome<Output> {
        let prefix = ChoiceSequence.flatten(tree)
        guard case let .success(output, _, _) = Materializer.materialize(
            gen, context: .init(
                prefix: prefix, mode: .exact, fallbackTree: tree,
                materializePicks: true
            )
        ) else {
            return .failure
        }
        return choiceGraphReduce(
            gen: gen,
            tree: tree,
            output: output,
            config: config,
            property: property
        )
    }
}
