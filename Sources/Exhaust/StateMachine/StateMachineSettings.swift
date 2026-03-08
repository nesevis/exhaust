// Configuration options for `#stateMachine` tests.
import ExhaustCore

/// Configuration options for `#stateMachine` state-machine property tests, passed as variadic arguments to control test behavior.
public enum StateMachineSettings {
    /// The range of command sequence lengths to generate.
    case sequenceLength(ClosedRange<Int>)

    /// The upper bound on random sampling iterations (default 100). Additive with the coverage budget.
    case maxIterations(UInt64)

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
}
