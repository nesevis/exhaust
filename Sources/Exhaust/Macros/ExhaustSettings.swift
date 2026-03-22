// Configuration options for `#exhaust` property tests.
//
// Pass these as variadic arguments to `#exhaust` to control test behavior:
// ```swift
// #exhaust(personGen, .samplingBudget(1000), .replay(42)) { person in
//     person.age >= 0
// }
// ```
import ExhaustCore

/// Configuration options for `#exhaust` property tests, passed as variadic arguments to control test behavior.
public enum ExhaustSettings<Output> {
    /// The upper bound on the number of randomly generated instances to test.
    case samplingBudget(UInt64)

    /// A fixed seed for deterministic replay (reproduction, benchmarking, regression).
    case replay(UInt64)

    /// The test case reduction configuration to use when a counterexample is found.
    case reductionBudget(TCRBudget)

    /// Suppresses test-framework issue reporting (`reportIssue`) on failure.
    ///
    /// Use this when the property test is *expected* to find a counterexample and the test asserts on the returned value rather than relying on the framework to record the failure.
    case suppressIssueReporting

    /// Reflects an existing value through the generator and attempts to reduce it.
    ///
    /// Skips random generation entirely. The value is reflected into a choice tree and then reduced using the property as the test case reduction oracle.
    ///
    /// The value must fail the property — if it passes, an issue is reported.
    case reflecting(Output)

    /// The iteration budget for structured coverage analysis (exhaustive enumeration, t-way covering arrays, boundary value covering arrays).
    ///
    /// This budget is *additive* with `samplingBudget` — structured coverage runs first, then random sampling runs for `samplingBudget` iterations. The default is 2000.
    ///
    /// When the generator's total space fits within this budget, `#exhaust` performs exhaustive enumeration and skips the random phase entirely.
    case coverageBudget(UInt64)

    /// Disables automatic structured coverage analysis.
    ///
    /// By default, `#exhaust` analyzes the generator's structure and selects a systematic coverage strategy: exhaustive enumeration for small finite domains, t-way covering arrays for larger finite domains, or boundary value covering arrays for generators with large explicit ranges. This runs before random sampling and uses its own budget (see ``coverageBudget``).
    ///
    /// When `.randomOnly` is set, `#exhaust` skips this analysis and proceeds directly to random sampling. Useful for benchmarking, comparing coverage strategies, or when the analysis overhead is unwanted.
    case randomOnly

    /// Reorders elements within type-homogeneous sibling groups into natural numeric order
    /// after test case reduction completes.
    case humanOrderPostProcess

    /// Prints the choice tree before and after reduction as a bottom-up Unicode visualization.
    case visualize
}
