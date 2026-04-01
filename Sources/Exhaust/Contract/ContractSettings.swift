// Configuration options for `#exhaust` contract tests.
import ExhaustCore

/// Configuration options for `#exhaust` contract property tests, passed as variadic arguments to control test behavior.
public enum ContractSettings {
    /// Controls iteration budgets for coverage, random sampling, and reduction. Defaults to `.expensive` (500 coverage rows, 500 random samplings, fast reduction).
    case budget(ExhaustBudget)

    /// A fixed seed for deterministic replay.
    ///
    /// Accepts a raw `UInt64` or a Crockford Base32 string.
    case replay(ReplaySeed)

    /// Suppresses test-framework issue reporting (`reportIssue`) on failure.
    case suppressIssueReporting

    /// Disables structured coverage analysis of command orderings.
    case randomOnly
}
