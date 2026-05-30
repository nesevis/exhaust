// Configuration options for concurrent contract tests via `#execute`.
import ExhaustCore

/// Configuration options for `#execute` concurrent contract property tests, passed as variadic arguments to control test behavior.
///
/// Concurrent contracts test interleaving at `await` boundaries using a cooperative scheduler. These settings control the concurrency level, idle timeout, sampling budget, and other test parameters.
///
/// ```swift
/// #execute(MySpec.self, .concurrent(4), .budget(.thorough))
/// ```
public enum ConcurrentContractSettings {
    /// Sets the number of concurrent execution lanes (1...8). Default is 2.
    ///
    /// Each lane runs its assigned commands in a separate Task. The cooperative scheduler interleaves their continuations at every `await` boundary. Higher values explore more complex interleavings but grow the search space combinatorially.
    ///
    /// With concurrency level 1, all commands run sequentially on a single lane — useful as a baseline to confirm that failures require concurrency.
    case concurrent(Int)

    /// Controls iteration budgets for coverage and random sampling. Defaults to `.standard`.
    case budget(ExhaustBudget)

    /// Limits the maximum number of commands per generated sequence. When omitted, the runner estimates a limit from the command generator's domain size and the coverage budget, capped at 40.
    case commandLimit(Int)

    /// Replays a specific test run using a fixed seed.
    ///
    /// Accepts a raw `UInt64` or a Crockford Base32 string. The same seed with the same concurrency level produces the same interleaving.
    case replay(ReplaySeed)

    /// Silences issue reporting, log output, or both for this contract test run.
    ///
    /// Use `.suppress(.issueReporting)` when the run is expected to find a failing command sequence and the test asserts on the returned value. Use `.suppress(.logs)` to silence console output. Use `.suppress(.all)` for a completely silent run.
    case suppress(SuppressOption)

    /// Sets the maximum milliseconds the drain loop waits with no pending continuations before declaring a timeout. Default is 1000.
    ///
    /// When the idle timeout fires, the test reports the current command sequence as a failure without attempting reduction (since each reduction probe would also timeout). The diagnostic indicates which command body likely suspended to a foreign executor.
    case idleTimeoutMs(Int)

    /// Collects per-example statistics in the OpenPBTStats JSON Lines format and attaches the result to the test run.
    ///
    /// Each test example produces one JSON line with status, a string representation, and complexity features derived from the choice tree. Compatible with the [Tyche](https://github.com/tyche-pbt/tyche-extension) visualization tool.
    case collectOpenPBTStats

    /// Registers a closure that receives an ``ExhaustReport`` after the test completes.
    ///
    /// The report includes per-phase timing, invocation counts, and reduction statistics. Multiple `.onReport` closures are chained in order.
    case onReport((ExhaustReport) -> Void)

    /// Controls log verbosity for this contract test run.
    ///
    /// Defaults to `.log(.error)` when omitted — only error-level messages appear.
    case log(LogLevel)
}
