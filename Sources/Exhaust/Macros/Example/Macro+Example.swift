import ExhaustCore

/// Generates a single value from a generator without running a property test.
///
/// Without a seed, the value is generated at a fixed size of 50 (midway on the 1–100 scale) so that size-dependent generators (arrays, strings, and so on) produce moderately complex output rather than minimal values. A plain numeric seed makes that value deterministic.
///
/// A seed copied from a failure report (for example `"5QF8M2-3"`) reproduces exactly the value the `#exhaust` sampling phase generated at that iteration, including its size. Coverage seeds (`U`-prefixed) are not replayable here and throw.
///
/// ```swift
/// let person = try #example(personGen)
/// let person = try #example(personGen, seed: 42)
/// let failing = try #example(personGen, seed: "5QF8M2-3")
/// ```
///
/// - Parameters:
///   - gen: The generator to produce an example from.
///   - seed: Optional seed for deterministic output. Accepts a raw `UInt64` or a Crockford Base32 string from a failure report.
/// - Returns: A single generated value.
@freestanding(expression)
public macro example<GeneratedValue>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    seed: ReplaySeed? = nil
) -> GeneratedValue = #externalMacro(module: "ExhaustMacros", type: "ExampleMacro")

/// Generates an array of values from a generator without running a property test.
///
/// Values come from the same interpreter as the `#exhaust` sampling phase, so with the same seed the array matches that phase's values one for one: sizes ramp across the 1–100 scale, and element `k` equals the value `#exhaust` tested at iteration `k`. A seed with an iteration suffix starts at that iteration instead of the first.
///
/// ```swift
/// let people = try #example(personGen, count: 10)
/// let people = try #example(personGen, count: 10, seed: 42)
/// ```
///
/// - Parameters:
///   - gen: The generator to produce examples from.
///   - count: The number of values to generate.
///   - seed: Optional seed for deterministic output. Accepts a raw `UInt64` or a Crockford Base32 string from a failure report.
/// - Returns: An array of generated values.
@freestanding(expression)
public macro example<GeneratedValue>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    count: Int,
    seed: ReplaySeed? = nil
) -> [GeneratedValue] = #externalMacro(module: "ExhaustMacros", type: "ExampleMacro")
