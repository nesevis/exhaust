/// Configuration options for `#exhaust` property tests.
///
/// Pass these as variadic arguments to `#exhaust` to control test behavior:
/// ```swift
/// #exhaust(personGen, .iterations(1000), .replay(42)) { person in
///     person.age >= 0
/// }
/// ```
@_spi(ExhaustInternal) import ExhaustCore

public enum ExhaustSettings {
    /// The maximum number of test iterations to run.
    case iterations(UInt64)

    /// A fixed seed for deterministic replay (reproduction, benchmarking, regression).
    case replay(UInt64)

    /// The shrink configuration to use when a counterexample is found.
    case shrinkBudget(Interpreters.ShrinkConfiguration)
}
