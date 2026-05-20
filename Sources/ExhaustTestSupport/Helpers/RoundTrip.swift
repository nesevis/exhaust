import ExhaustCore
import Testing

/// Generates a single value, reflects it into a choice sequence, materialises from that
/// sequence, and returns both the original and materialised values for comparison.
package func roundTrip<Output: Equatable>(
    _ gen: Generator<Output>,
    seed: UInt64 = 42
) throws -> (original: Output, materialized: Output) {
    var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: seed)
    let (value, tree) = try #require(try interpreter.prefix(1).last)
    let flattened = ChoiceSequence.flatten(tree)
    guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: flattened, mode: .exact, fallbackTree: tree) else {
        Issue.record("Expected .success")
        return (value, value)
    }
    return (value, materialized)
}

/// Batch variant: generates multiple values and round-trips each through materialise.
package func roundTripBatch<Output: Equatable>(
    _ gen: Generator<Output>,
    seed: UInt64 = 42,
    maxRuns: UInt64 = 20
) throws -> [(original: Output, materialized: Output)] {
    var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: seed, maxRuns: maxRuns)
    var results: [(original: Output, materialized: Output)] = []
    while let (value, tree) = try iterator.next() {
        let sequence = ChoiceSequence(tree)
        guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: tree) else {
            Issue.record("Expected .success")
            continue
        }
        results.append((value, materialized))
    }
    return results
}
