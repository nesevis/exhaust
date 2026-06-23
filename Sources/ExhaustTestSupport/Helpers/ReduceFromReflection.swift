import ExhaustCore
import Testing

/// Reflects a value into a choice tree and reduces it, returning the best counterexample.
///
/// Returns the reduced value when reduction improves the counterexample, the original value when it does not, or the original value when reduction fails entirely. Use this in tests that start from a known value and want the reducer's best effort.
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
    let outcome = try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: config, property: property)
    switch outcome {
        case let .reduced(_, _, output): return output
        case let .unreduced(_, _, output): return output
        case .failure: return value
    }
}
