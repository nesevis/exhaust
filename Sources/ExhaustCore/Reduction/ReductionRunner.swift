//
//  ReductionRunner.swift
//  Exhaust
//

// MARK: - Reduction Runner

/// Reduces a counterexample on behalf of a test runner, applying the run's deadline and reporting the reduced value together with its statistics.
///
/// Callers read property invocation counts from ``Run/propertyInvocations`` and ``Run/propertyFailures`` rather than wrapping the property in a counter: every property call the reducer makes is recorded in ``ReductionStats``. A caller whose property returns early without consulting the user's property (for example, a direction gate) counts the user's property itself.
///
/// - SeeAlso: ``Interpreters/choiceGraphReduceCollectingStats(gen:tree:output:config:property:)``
package enum ReductionRunner {
    /// The counterexample a reduction ended with, and how it got there.
    package struct Run<Output> {
        /// The reducer's canonical sequence for ``value``. Not necessarily `ChoiceSequence.flatten(tree)`: the reducer re-encodes its input before the first cycle.
        package let sequence: ChoiceSequence
        package let tree: ChoiceTree
        package let value: Output
        /// Whether the reducer produced a sequence different from the one it started from.
        package let improved: Bool
        /// Empty when the run's deadline had already passed and reduction never started.
        package let stats: ReductionStats
        /// False when the run's deadline had already passed, so the input comes back unchanged.
        package let started: Bool

        /// Property calls made by the reducer.
        package var propertyInvocations: Int {
            stats.reductionProbesWherePropertyPassed + stats.reductionProbesWherePropertyFailed
        }

        /// Property calls made by the reducer that falsified the property.
        package var propertyFailures: Int {
            stats.reductionProbesWherePropertyFailed
        }
    }

    /// Reduces `value` while `property` keeps failing.
    ///
    /// When `runDeadlineNanoseconds` is set, the configuration's wall-clock budget is clamped to the time remaining before it. A configured budget of zero means unlimited, so it is replaced by the remaining time. A deadline that has already passed returns the input unchanged without starting the reducer.
    ///
    /// - Parameters:
    ///   - generator: The generator that produced `value`.
    ///   - tree: The choice tree for `value`.
    ///   - value: The failing value.
    ///   - configuration: Reducer configuration. Its wall-clock budget is relative to the start of reduction.
    ///   - runDeadlineNanoseconds: Absolute monotonic deadline for the whole run, or nil for none.
    ///   - property: Returns `true` when a candidate passes. Reduction keeps candidates for which it returns `false`.
    package static func reduce<Output>(
        _ generator: Generator<Output>,
        tree: ChoiceTree,
        value: Output,
        configuration: Interpreters.ReducerConfiguration,
        runDeadlineNanoseconds: UInt64? = nil,
        property: (Output) -> Bool
    ) -> Run<Output> {
        var configuration = configuration
        if let runDeadlineNanoseconds {
            let now = monotonicNanoseconds()
            guard now < runDeadlineNanoseconds else {
                return Run(
                    sequence: ChoiceSequence.flatten(tree),
                    tree: tree,
                    value: value,
                    improved: false,
                    stats: ReductionStats(),
                    started: false
                )
            }
            let remaining = runDeadlineNanoseconds - now
            let configured = configuration.wallClockDeadlineNanoseconds
            configuration.wallClockDeadlineNanoseconds = configured == 0 ? remaining : min(configured, remaining)
        }

        let result = Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: tree,
            output: value,
            config: configuration,
            property: property
        )
        switch result.outcome {
            case let .reduced(sequence, reducedTree, reducedValue):
                return Run(
                    sequence: sequence,
                    tree: reducedTree,
                    value: reducedValue,
                    improved: true,
                    stats: result.stats,
                    started: true
                )
            case let .unreduced(sequence, unreducedTree, unreducedValue):
                return Run(
                    sequence: sequence,
                    tree: unreducedTree,
                    value: unreducedValue,
                    improved: false,
                    stats: result.stats,
                    started: true
                )
            case .failure:
                return Run(
                    sequence: ChoiceSequence.flatten(tree),
                    tree: tree,
                    value: value,
                    improved: false,
                    stats: result.stats,
                    started: true
                )
        }
    }
}
