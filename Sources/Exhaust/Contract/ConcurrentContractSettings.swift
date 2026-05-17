// Configuration options for concurrent contract tests via `#exhaust`.
import ExhaustCore

/// Configuration options for `#exhaust` concurrent contract property tests, passed as variadic arguments to control test behavior.
///
/// Concurrent contracts test interleaving at `await` boundaries using a cooperative scheduler. These settings control the concurrency level, idle timeout, sampling budget, and other test parameters.
///
/// ```swift
/// #exhaust(MySpec.self, .concurrency(4), .budget(.thorough))
/// ```
public enum ConcurrentContractSettings {
    /// Number of concurrent execution lanes (1...8). Default is 2.
    ///
    /// Each lane runs its assigned commands in a separate Task. The cooperative scheduler interleaves their continuations at every `await` boundary. Higher values explore more complex interleavings but grow the search space combinatorially.
    ///
    /// With concurrency level 1, all commands run sequentially on a single lane — useful as a baseline to confirm that failures require concurrency.
    case concurrency(Int)

    /// Controls iteration budgets for coverage and random sampling. Defaults to `.thorough`.
    case budget(ExhaustBudget)

    /// Maximum number of commands per generated sequence. Default is 10.
    case commandLimit(Int)

    /// Replays a specific test run using a fixed seed.
    ///
    /// Accepts a raw `UInt64` or a Crockford Base32 string. The same seed with the same concurrency level produces the same interleaving.
    case replay(ReplaySeed)

    /// Silences issue reporting, log output, or both for this contract test run.
    ///
    /// Use `.suppress(.issueReporting)` when the run is expected to find a failing command sequence and the test asserts on the returned value. Use `.suppress(.logs)` to silence console output. Use `.suppress(.all)` for a completely silent run.
    case suppress(SuppressOption)

    /// Maximum milliseconds the drain loop waits with no pending continuations before declaring a timeout. Default is 1000.
    ///
    /// When the idle timeout fires, the test reports the current command sequence as a failure without attempting reduction (since each reduction probe would also timeout). The diagnostic indicates which command body likely suspended to a foreign executor.
    case idleTimeout(Int)

    /// Controls log verbosity and format for this contract test run.
    ///
    /// Defaults to `.logging(.error, .keyValue)` when omitted — only error-level messages appear.
    case logging(LogLevel, LogFormat = .keyValue)
}
