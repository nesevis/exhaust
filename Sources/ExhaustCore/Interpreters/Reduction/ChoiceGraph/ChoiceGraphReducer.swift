//
//  ChoiceGraphReducer.swift
//  Exhaust
//

// MARK: - Choice Graph Reducer

public extension Interpreters {
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
    /// - Returns: The reduced (sequence, output) pair, or `nil` if reduction could not improve the result.
    static func choiceGraphReduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        output: Output,
        config: ReducerConfiguration,
        property: (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        if config.visualize {
            print("── Before reduction ──")
            print(tree.visualization(width: 100))
        }

        let result = try withoutActuallyEscaping(property) { escapingProperty in
            try ChoiceGraphScheduler.run(
                gen: gen,
                initialTree: tree,
                initialOutput: output,
                config: config,
                property: escapingProperty
            )
        }

        if config.visualize, let (resultSequence, _) = result {
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

    /// Reduces a failing counterexample using the graph-based pipeline and returns accumulated statistics.
    ///
    /// - Returns: The reduced result and a ``ReductionStats`` value summarizing encoder probe counts, materialization attempts, and cycle count.
    static func choiceGraphReduceCollectingStats<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        output: Output,
        config: ReducerConfiguration,
        property: (Output) -> Bool
    ) throws -> (reduced: (ChoiceSequence, Output)?, stats: ReductionStats) {
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

        if config.visualize, let (resultSequence, _) = result.reduced {
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

    /// Convenience overload that materialises the output from the tree before reducing.
    static func choiceGraphReduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: ReducerConfiguration,
        property: (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        let prefix = ChoiceSequence.flatten(tree)
        guard case let .success(output, _, _) = Materializer.materialize(
            gen, prefix: prefix, mode: .exact, fallbackTree: tree,
            materializePicks: true
        ) else {
            return nil
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
