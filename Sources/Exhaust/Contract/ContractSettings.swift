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

    /// Silences issue reporting, log output, or both for this contract test run.
    ///
    /// Use `.suppress(.issueReporting)` when the run is expected to find a failing command sequence and the test asserts on the returned value. Use `.suppress(.logs)` to silence console output. Use `.suppress(.all)` for a completely silent run.
    case suppress(SuppressOption)

    /// Disables structured coverage analysis of command orderings.
    case randomOnly

    /// Collects per-example statistics in the OpenPBTStats JSON Lines format and attaches the result to the test run.
    ///
    /// Each test example produces one JSON line with status, a `customDump` representation, and complexity features derived from the choice tree. Compatible with the [Tyche](https://github.com/tyche-pbt/tyche-extension) visualization tool.
    case collectOpenPBTStats

    /// Controls log verbosity and format for this contract test run.
    ///
    /// Defaults to `.logging(.error, .keyValue)` when omitted — only error-level messages appear.
    case logging(LogLevel, LogFormat = .keyValue)
}
