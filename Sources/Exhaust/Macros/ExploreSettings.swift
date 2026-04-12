// Configuration options for `#explore` feedback-guided property tests.
//
// Pass these as variadic arguments to `#explore` to control test behavior:
// ```swift
// let counterexample = #explore(personGen, .samplingBudget(10_000),
//     scorer: { Double($0.age) }
// ) { person in
//     person.age >= 0
// }
// ```
import ExhaustCore

/// Configuration options for `#explore` feedback-guided property tests, passed as variadic arguments to control test behavior.
public enum ExploreSettings {
    /// The upper bound on the number of test iterations to run.
    case samplingBudget(UInt64)

    /// A fixed seed for deterministic replay (reproduction, benchmarking, regression).
    ///
    /// Accepts a raw `UInt64` or a Crockford Base32 string.
    case replay(ReplaySeed)

    /// Suppresses test-framework issue reporting (`reportIssue`) on failure.
    ///
    /// Use this when the property test is *expected* to find a counterexample and the test asserts on the returned value rather than relying on the framework to record the failure.
    case suppressIssueReporting

    /// Maximum number of seeds to keep in the pool.
    case poolCapacity(Int)

    /// Probability of generating a fresh value vs. mutating an existing seed.
    /// Default is 0.2 (20% fresh, 80% mutation).
    case generateRatio(Double)

    /// Controls log verbosity and format for this explore run.
    ///
    /// Defaults to `.logging(.error, .keyValue)` when omitted — only error-level messages appear.
    case logging(LogLevel, LogFormat = .keyValue)
}
