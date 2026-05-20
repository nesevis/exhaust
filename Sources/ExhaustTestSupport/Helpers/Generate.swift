import ExhaustCore
import Testing

/// Generates a value and its choice tree from a generator with a given seed.
///
/// - Parameter iteration: Zero-based index of the generated value to return.
///   Defaults to 0 (the first value). Pass a higher number to skip earlier values
///   and return a later one from the same PRNG stream.
package func generate<Output>(
    _ gen: Generator<Output>,
    seed: UInt64 = 42,
    iteration: Int = 0
) throws -> (value: Output, tree: ChoiceTree) {
    var iter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed)
    return try #require(iter.prefix(iteration + 1).last)
}
