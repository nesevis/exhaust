// Configuration options for `#exhaust` tests.
import ExhaustCore

/// Configuration options for `#exhaust` contract property tests, passed as variadic arguments to control test behavior.
public enum ContractSettings {
    /// The upper bound on random sampling iterations (default 100). Additive with the coverage budget.
    case samplingBudget(UInt64)

    /// Maximum test cases for structured coverage of command orderings (default 2000).
    case coverageBudget(UInt64)

    /// A fixed seed for deterministic replay.
    case replay(UInt64)

    /// The test case reduction configuration to use when a counterexample is found.
    case reductionBudget(TCRBudget)

    /// Suppresses test-framework issue reporting (`reportIssue`) on failure.
    case suppressIssueReporting

    /// Disables structured coverage analysis of command orderings.
    case randomOnly

    /// Includes command argument values in SCA domain construction.
    ///
    /// By default, SCA covers command-type orderings only, keeping the domain small enough for higher interaction strengths (t=3, t=4). With this setting, each position's domain is the flattened union of `(commandType × argumentCombinations)`, giving IPOG pairwise coverage of both command ordering and argument value interactions — at the cost of larger domains that typically cap at t=2.
    case argumentAwareCoverage
}
