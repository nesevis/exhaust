import ExhaustCore
import Testing

/// Runs a generator repeatedly and asserts that every generated value satisfies the property.
///
/// This is a generate-only check — no shrinking or reduction. Use it to validate
/// invariants of generators or utility functions across many random inputs.
package func exhaustCheck<Value>(
    _ gen: Generator<Value>,
    maxIterations: UInt64 = 100,
    seed: UInt64 = 42,
    property: (Value) -> Bool
) throws {
    var iter = ValueInterpreter(gen, seed: seed, maxRuns: maxIterations)
    while let value = try iter.next() {
        #expect(property(value), "Property failed for value: \(value)")
    }
}

/// Two-tuple variant that unpacks the generated pair before passing to the property.
package func exhaustCheck<A, B>(
    _ gen: Generator<(A, B)>,
    maxIterations: UInt64 = 200,
    seed: UInt64 = 42,
    property: (A, B) -> Bool
) throws {
    var iter = ValueInterpreter(gen, seed: seed, maxRuns: maxIterations)
    while let value = try iter.next() {
        #expect(property(value.0, value.1), "Property failed for value: \(value)")
    }
}
