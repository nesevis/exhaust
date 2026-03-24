// Configuration options for `#exhaust` contract tests.
import ExhaustCore

/// Configuration options for `#exhaust` contract property tests, passed as variadic arguments to control test behavior.
public enum ContractSettings {
    /// Controls iteration budgets for coverage, random sampling, and reduction. Defaults to `.expensive` (500 coverage rows, 500 random samplings, fast reduction).
    case budget(ExhaustBudget)

    /// A fixed seed for deterministic replay.
    case replay(UInt64)

    /// Suppresses test-framework issue reporting (`reportIssue`) on failure.
    case suppressIssueReporting

    /// Disables structured coverage analysis of command orderings.
    case randomOnly

    /// Includes command argument values in SCA domain construction.
    ///
    /// By default, SCA covers command-type orderings only, keeping the domain small enough for higher interaction strengths (t=3, t=4). With this setting, each position's domain is the flattened union of `(commandType × argumentCombinations)`, giving pairwise coverage of both command ordering and argument value interactions — at the cost of larger domains that typically cap at t=2.
    case argumentAwareCoverage
}
