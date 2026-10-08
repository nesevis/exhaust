//
//  ExploreReduction.swift
//  Exhaust
//

// MARK: - Explore Reduction

/// Direction classification and direction-preserving reduction, shared by ``DirectedExploreRunner`` and the parallel explore lanes.
enum ExploreReduction {
    /// Returns the indices of every direction whose predicate `value` satisfies, in declaration order.
    static func classify<Output>(
        _ value: Output,
        directions: [(name: String, predicate: (Output) -> Bool)]
    ) -> [Int] {
        var matching = [Int]()
        for index in 0 ..< directions.count where directions[index].predicate(value) {
            matching.append(index)
        }
        return matching
    }

    /// Reduces a failure while it keeps failing the property and keeps matching every direction it matched when found.
    ///
    /// A candidate that drops one of `matchingDirections` is rejected without running the property, so the reported invocation and failure counts cover the user's property alone, not every probe the reducer made.
    static func reduce<Output>(
        gen: Generator<Output>,
        property: @escaping (Output) -> Bool,
        directions: [(name: String, predicate: (Output) -> Bool)],
        value: Output,
        tree: ChoiceTree,
        matchingDirections: [Int]
    ) -> ReducedFailure<Output> {
        let countingProperty = PropertyOutcomeCounter(property)
        let reductionPredicate: (Output) -> Bool = matchingDirections.isEmpty
            ? { output in
                countingProperty(output) == false
            }
            : { output in
                for directionIndex in matchingDirections where directions[directionIndex].predicate(output) == false {
                    return false
                }
                return countingProperty(output) == false
            }

        let run = ReductionRunner.reduce(
            gen,
            tree: tree,
            value: value,
            configuration: .init(maxStalls: 2),
            property: { reductionPredicate($0) == false }
        )
        if run.improved {
            return ReducedFailure(
                counterexample: run.value,
                original: value,
                reducedSequence: run.sequence,
                reductionInvocations: countingProperty.invocations,
                reductionFailures: countingProperty.failures
            )
        }

        return ReducedFailure(
            counterexample: value,
            original: value,
            reducedSequence: nil,
            reductionInvocations: countingProperty.invocations,
            reductionFailures: countingProperty.failures
        )
    }
}

// MARK: - Reduced Failure

/// A failure after direction-preserving reduction, with the property outcomes reduction spent.
struct ReducedFailure<Output> {
    var counterexample: Output
    var original: Output
    /// Nil when reduction did not improve the failure.
    var reducedSequence: ChoiceSequence?
    var reductionInvocations: Int
    /// Probes whose property invocation reproduced the failure, disjoint from direction-mismatched probes (which never invoke the property).
    var reductionFailures: Int
}
