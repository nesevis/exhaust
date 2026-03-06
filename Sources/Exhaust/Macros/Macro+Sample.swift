// Generates a single value from a generator without running a property test.
//
// The generated value uses a fixed size of 50 (midway on the 1–100 scale)
// so that size-dependent generators (arrays, strings, etc.) produce
// moderately complex output rather than minimal values.
//
// ```swift
// let person = #sample(personGen)
// let person = #sample(personGen, seed: 42)
// ```
//
// - Parameters:
//   - gen: The generator to sample from.
//   - seed: Optional seed for deterministic replay.
// - Returns: A single generated value.
import ExhaustCore

@freestanding(expression)
public macro sample<T>(
    _ gen: ReflectiveGenerator<T>,
    seed: UInt64? = nil,
) -> T = #externalMacro(module: "ExhaustMacros", type: "SampleMacro")

/// Generates an array of values from a generator without running a property test.
///
/// Each element is generated at increasing size (cycling 1–100), so earlier
/// elements tend to be simpler and later elements more complex.
///
/// ```swift
/// let people = #sample(personGen, count: 10)
/// let people = #sample(personGen, count: 10, seed: 42)
/// ```
///
/// - Parameters:
///   - gen: The generator to sample from.
///   - count: The number of values to generate.
///   - seed: Optional seed for deterministic replay.
/// - Returns: An array of generated values.
@freestanding(expression)
public macro sample<T>(
    _ gen: ReflectiveGenerator<T>,
    count: UInt64,
    seed: UInt64? = nil,
) -> [T] = #externalMacro(module: "ExhaustMacros", type: "SampleMacro")
