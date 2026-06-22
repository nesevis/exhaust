//
//  ChoiceGraphReducer.swift
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

// MARK: - Choice Graph Reducer

package extension Interpreters {
    /// Reduces a failing counterexample using the graph-based reduction pipeline.
    ///
    /// Builds a ``ChoiceGraph`` from the failing tree and drives four graph encoders (branch pivot, deletion, value search, redistribution) in a cycle loop until convergence.
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
    ) throws -> ReductionOutcome<Output> {
        if config.visualize {
            print("── Before reduction ──")
            print(tree.visualization(width: 100))
        }

        let outcome = try withoutActuallyEscaping(property) { escapingProperty in
            try ChoiceGraphScheduler.run(
                gen: gen,
                initialTree: tree,
                initialOutput: output,
                config: config,
                property: escapingProperty
            )
        }

        if config.visualize, let (resultSequence, _) = outcome.counterexample {
            let resultTree = Materializer.materialize(
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

        return outcome
    }

    /// Reduces a failing counterexample using the graph-based pipeline and returns accumulated statistics.
    ///
    /// - Returns: A ``ReductionOutcome`` and a ``ReductionStats`` value summarizing encoder probe counts, materialization attempts, and cycle count.
    static func choiceGraphReduceCollectingStats<Output>(
        gen: Generator<Output>,
        tree: ChoiceTree,
        output: Output,
        config: ReducerConfiguration,
        property: (Output) -> Bool
    ) throws -> (outcome: ReductionOutcome<Output>, stats: ReductionStats) {
        if config.visualize {
            print("── Before reduction ──")
            print(tree.visualization(width: 100))
        }

        let result = try withoutActuallyEscaping(property) { escapingProperty in
            try ChoiceGraphScheduler.runCollectingStats(
                gen: gen,
                initialTree: tree,
                initialOutput: output,
                config: config,
                property: escapingProperty
            )
        }

        if config.visualize, let (resultSequence, _) = result.outcome.counterexample {
            let resultTree = Materializer.materialize(
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

    /// Convenience overload that materializes the output from the tree before reducing.
    static func choiceGraphReduce<Output>(
        gen: Generator<Output>,
        tree: ChoiceTree,
        config: ReducerConfiguration,
        property: (Output) -> Bool
    ) throws -> ReductionOutcome<Output> {
        let prefix = ChoiceSequence.flatten(tree)
        guard case let .success(output, _, _) = Materializer.materialize(
            gen, prefix: prefix, mode: .exact, fallbackTree: tree,
            materializePicks: true
        ) else {
            return .failure
        }
        return try choiceGraphReduce(
            gen: gen,
            tree: tree,
            output: output,
            config: config,
            property: property
        )
    }
}
