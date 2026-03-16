// Generates a single value from a generator without running a property test.
//
// The generated value uses a fixed size of 50 (midway on the 1–100 scale)
// so that size-dependent generators (arrays, strings, etc.) produce
// moderately complex output rather than minimal values.
//
// ```swift
// let person = #example(personGen)
// let person = #example(personGen, seed: 42)
// ```
//
// - Parameters:
//   - gen: The generator to produce an example from.
//   - seed: Optional seed for deterministic replay.
// - Returns: A single generated value.
import ExhaustCore

@freestanding(expression)
public macro example<T>(
    _ gen: ReflectiveGenerator<T>,
    seed: UInt64? = nil
) -> T = #externalMacro(module: "ExhaustMacros", type: "ExampleMacro")

/// Generates an array of values from a generator without running a property test.
///
/// Each element is generated at increasing size (cycling 1–100), so earlier elements tend to be simpler and later elements more complex.
///
/// ```swift
/// let people = #example(personGen, count: 10)
/// let people = #example(personGen, count: 10, seed: 42)
/// ```
///
/// - Parameters:
///   - gen: The generator to produce examples from.
///   - count: The number of values to generate.
///   - seed: Optional seed for deterministic replay.
/// - Returns: An array of generated values.
@freestanding(expression)
public macro example<T>(
    _ gen: ReflectiveGenerator<T>,
    count: UInt64,
    seed: UInt64? = nil
) -> [T] = #externalMacro(module: "ExhaustMacros", type: "ExampleMacro")
