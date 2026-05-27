import ExhaustCore
import Testing

/// Searches for the minimal counterexample to a property using generation and graph-based reduction.
///
/// Generates values from `gen`, checks each against `property`, and when a failure is found,
/// reduces it via `choiceGraphReduce` to find the smallest failing input. This is the
/// ExhaustCore-level equivalent of `#exhaust` — no macros or `ReflectiveGenerator` needed.
///
/// - Returns: The minimal counterexample, or nil if the property holds for all generated values.
package func findMinimalCounterexample<Value>(
    _ gen: Generator<Value>,
    maxIterations: UInt64 = 100,
    seed: UInt64 = 42,
    maxStalls: Int = 2,
    property: (Value) -> Bool
) throws -> Value? {
    var iter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed, maxRuns: maxIterations)
    while let (value, tree) = try iter.next() {
        guard property(value) == false else { continue }
        let outcome = try Interpreters.choiceGraphReduce(
            gen: gen, tree: tree, config: .init(maxStalls: maxStalls), property: property
        )
        if case let .reduced(_, reduced) = outcome {
            return reduced
        }
        return value
    }
    return nil
}
