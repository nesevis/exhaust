import ExhaustCore
import Testing

/// Generates and round-trips multiple values through exact materialization.
package func roundTripBatch<Output: Equatable>(
    _ generator: Generator<Output>,
    seed: UInt64 = 42,
    maxRuns: UInt64 = 20
) throws -> [(original: Output, materialized: Output)] {
    var iterator = ValueAndChoiceTreeInterpreter(
        generator,
        materializePicks: false,
        seed: seed,
        maxRuns: maxRuns
    )
    var results: [(original: Output, materialized: Output)] = []
    while let (value, tree) = try iterator.next() {
        let sequence = ChoiceSequence(tree)
        guard case let .success(materialized, _, _) = Materializer.materialize(
            generator,
            prefix: sequence,
            mode: .exact,
            fallbackTree: tree
        ) else {
            Issue.record("Expected .success")
            continue
        }
        results.append((value, materialized))
    }
    return results
}
