// Configuration options for `#exhaust` property tests.
//
// Pass these as variadic arguments to `#exhaust` to control test behavior:
// ```swift
// #exhaust(personGen, .maxIterations(1000), .replay(42)) { person in
//     person.age >= 0
// }
// ```
import ExhaustCore

public enum ExhaustSettings<Output> {
    /// The upper bound on the number of test iterations to run.
    case maxIterations(UInt64)

    /// A fixed seed for deterministic replay (reproduction, benchmarking, regression).
    case replay(UInt64)

    /// The shrink configuration to use when a counterexample is found.
    case shrinkBudget(ShrinkBudget)

    /// Suppresses test-framework issue reporting (`reportIssue`) on failure.
    ///
    /// Use this when the property test is *expected* to find a counterexample and the test asserts on the returned value rather than relying on the framework to record the failure.
    case suppressIssueReporting

    /// Reflects an existing value through the generator and attempts to reduce it.
    ///
    /// Skips random generation entirely. The value is reflected into a choice tree and then reduced using the property as the shrinking oracle.
    ///
    /// The value must fail the property — if it passes, an issue is reported.
    case reflecting(Output)

    /// The iteration budget for structured coverage analysis (exhaustive enumeration, t-way covering arrays, boundary value covering arrays).
    ///
    /// This budget is *additive* with `maxIterations` — structured coverage runs first, then random sampling runs for `maxIterations` iterations. The default is 2000.
    ///
    /// When the generator's total space fits within this budget, `#exhaust` performs exhaustive enumeration and skips the random phase entirely.
    case coverageBudget(UInt64)

    /// Disables automatic structured coverage analysis.
    ///
    /// By default, `#exhaust` analyzes the generator's structure and selects a systematic coverage strategy: exhaustive enumeration for small finite domains, t-way covering arrays for larger finite domains, or boundary value covering arrays for generators with large explicit ranges. This runs before random sampling and uses its own budget (see ``coverageBudget``).
    ///
    /// When `.randomOnly` is set, `#exhaust` skips this analysis and proceeds directly to random sampling. Useful for benchmarking, comparing coverage strategies, or when the analysis overhead is unwanted.
    case randomOnly
}
