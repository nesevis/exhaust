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

    /// Ensures only unique values are yielded, using the flattened `ChoiceSequence` as the
    /// deduplication key. When combined with `.iterations(n)`, produces `n` unique values.
    ///
    /// - Parameter maxAttempts: The maximum number of generation attempts before giving up.
    ///   If the budget is exhausted before `iterations` unique values are produced, a warning
    ///   is logged and generation stops early.
    case unique(maxAttempts: UInt64)
}
