import ExhaustCore
import Testing

/// Reflects a value into a choice tree and reduces it, returning the best counterexample.
///
/// Returns the reduced value or the unchanged counterexample. A failed reduction records a test failure rather than silently returning the original input.
///
/// - Parameters:
///   - gen: The generator that describes the value's structure.
///   - value: The starting value to reflect and reduce.
///   - config: Reducer configuration. Defaults to two stalls.
///   - property: The property to minimize against.
/// - Returns: The best counterexample the reducer could find.
package func reduceFromReflection<Output>(
    _ gen: Generator<Output>,
    startingAt value: Output,
    config: Interpreters.ReducerConfiguration = .init(maxStalls: 2),
    property: (Output) -> Bool
) throws -> Output {
    let tree = try #require(try Interpreters.reflect(gen, with: value))
    let outcome = Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: config, property: property)
    return try #require(outcome.counterexample).1
}
