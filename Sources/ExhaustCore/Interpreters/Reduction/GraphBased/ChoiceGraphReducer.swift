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
        config: BonsaiReducerConfiguration,
        property: (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        try withoutActuallyEscaping(property) { escapingProperty in
            try ChoiceGraphScheduler.run(
                gen: gen,
                initialTree: tree,
                initialOutput: output,
                config: config,
                property: escapingProperty
            )
        }
    }

    /// Reduces a failing counterexample using the graph-based pipeline and returns accumulated statistics.
    ///
    /// - Returns: The reduced result and a ``ReductionStats`` value summarising encoder probe counts, materialisation attempts, and cycle count.
    static func choiceGraphReduceCollectingStats<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        output: Output,
        config: BonsaiReducerConfiguration,
        property: (Output) -> Bool
    ) throws -> (reduced: (ChoiceSequence, Output)?, stats: ReductionStats) {
        try withoutActuallyEscaping(property) { escapingProperty in
            try ChoiceGraphScheduler.runCollectingStats(
                gen: gen,
                initialTree: tree,
                initialOutput: output,
                config: config,
                property: escapingProperty
            )
        }
    }

    /// Convenience overload that materialises the output from the tree before reducing.
    static func choiceGraphReduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: BonsaiReducerConfiguration,
        property: (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        let prefix = ChoiceSequence.flatten(tree)
        guard case let .success(output, _, _) = Materializer.materialize(
            gen, prefix: prefix, mode: .exact, fallbackTree: tree
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
