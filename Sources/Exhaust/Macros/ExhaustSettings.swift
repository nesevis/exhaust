/// Configuration options for `#exhaust` property tests.
///
/// Pass these as variadic arguments to `#exhaust` to control test behavior:
/// ```swift
/// #exhaust(personGen, .iterations(1000), .seed(42)) { person in
///     person.age >= 0
/// }
/// ```
public enum ExhaustSettings {
    /// The maximum number of test iterations to run.
    case iterations(UInt64)

    /// A fixed seed for deterministic reproduction.
    case seed(UInt64)

    /// The shrink configuration to use when a counterexample is found.
    case shrinkBudget(Interpreters.ShrinkConfiguration)
}
