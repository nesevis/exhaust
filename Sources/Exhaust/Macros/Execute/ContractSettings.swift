// Configuration options for `#execute` contract tests.
import ExhaustCore

/// Configuration options for `#execute` contract property tests, passed as variadic arguments to control test behavior.
public enum ContractSettings {
    /// Limits the maximum number of commands per generated sequence. When omitted, the runner estimates a default from the command generator's domain size and the coverage budget. Defaults vary by mode: `.sequential` uses the estimate (its budget-derived ceiling tops out at 100, with a floor of three appearances per command type), `.tasks` caps the estimate at 40, and `.threads` uses a flat default of 10.
    case commandLimit(Int)

    /// Controls iteration budgets for coverage and random sampling. Defaults to `.standard` (200 coverage rows, 200 random samplings).
    case budget(ExhaustBudget)

    /// Replays a specific test run using a fixed seed.
    ///
    /// Accepts a raw `UInt64` or a Crockford Base32 string.
    case replay(ReplaySeed)

    /// Silences issue reporting, log output, or both for this contract test run.
    ///
    /// Use `.suppress(.issueReporting)` when the run is expected to find a failing command sequence and the test asserts on the returned value. Use `.suppress(.logs)` to silence console output. Use `.suppress(.all)` for a completely silent run.
    case suppress(SuppressOption)

    /// Registers a closure that receives an ``ExhaustReport`` after the test completes.
    ///
    /// The report includes per-phase timing, invocation counts, and reduction statistics. Multiple `.onReport` closures are chained in order.
    case onReport((ExhaustReport) -> Void)

    /// Controls log verbosity for this contract test run.
    ///
    /// Defaults to `.log(.error)` when omitted — only error-level messages appear.
    case log(LogLevel)

    /// Sets the number of concurrent execution lanes. Default is ``ConcurrencyLevel/two``.
    ///
    /// Each lane runs its assigned commands concurrently. For `.tasks` contracts, the cooperative scheduler interleaves continuations at every `await` boundary. For `.threads` contracts, each lane dispatches to a separate GCD thread.
    case parallelize(lanes: ConcurrencyLevel)

    /// Sets the maximum milliseconds the drain loop waits with no pending continuations before declaring a timeout. Default is 2000.
    ///
    /// When the idle timeout fires, the test reports the current command sequence as a failure without attempting reduction (since each reduction probe would also time out).
    case idleTimeoutMs(Int)
}
