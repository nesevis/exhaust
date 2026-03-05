// Configuration options for `#exhaust` property tests.
//
// Pass these as variadic arguments to `#exhaust` to control test behavior:
// ```swift
// #exhaust(personGen, .maxIterations(1000), .replay(42)) { person in
//     person.age >= 0
// }
// ```
@_spi(ExhaustInternal) import ExhaustCore

public enum ExhaustSettings<Output> {
    /// The upper bound on the number of test iterations to run.
    case maxIterations(UInt64)

    /// A fixed seed for deterministic replay (reproduction, benchmarking, regression).
    case replay(UInt64)

    /// The shrink configuration to use when a counterexample is found.
    case shrinkBudget(ShrinkBudget)

    /// Suppresses test-framework issue reporting (`reportIssue`) on failure.
    ///
    /// Use this when the property test is *expected* to find a counterexample and
    /// the test asserts on the returned value rather than relying on the framework
    /// to record the failure.
    case suppressIssueReporting

    /// Reflects an existing value through the generator and attempts to reduce it.
    ///
    /// Skips random generation entirely. The value is reflected into a choice tree
    /// and then reduced using the property as the shrinking oracle.
    ///
    /// The value must fail the property — if it passes, an issue is reported.
    case reflecting(Output)

    /// Disables automatic t-way covering array analysis.
    ///
    /// By default, `#exhaust` detects generators composed entirely of finite-domain
    /// elements (booleans, small enums, bounded integral ranges) and uses IPOG covering
    /// arrays to guarantee that every t-tuple of parameter values is tested. An
    /// empirical study of real-world software faults found that pairwise (t=2)
    /// coverage catches ~93% of interaction bugs, and 3-way (t=3) catches ~98%
    /// (Kuhn, Wallace & Gallo, "Software Fault Interactions and Implications for
    /// Software Testing", IEEE TSE 2004).
    ///
    /// When `.randomOnly` is set, `#exhaust` skips this analysis and proceeds
    /// directly to random sampling. Useful for benchmarking, comparing coverage
    /// strategies, or when the analysis overhead is unwanted.
    case randomOnly
}
