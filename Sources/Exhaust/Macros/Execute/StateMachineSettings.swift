// Configuration options for `#execute` spec tests.
import ExhaustCore

/// Configuration options for `#execute` spec tests, passed as variadic arguments to control test behavior.
public enum StateMachineSettings {
    /// Limits the maximum number of commands per generated sequence. When omitted, the runner estimates a default from the command generator's domain size and the screening budget. Defaults vary by mode: `.sequential` uses the estimate (its budget-derived ceiling tops out at 100, with a floor of three appearances per command type), `.tasks` caps the estimate at 40, and `.threads` uses a flat default of 10. A spec that declares an `@Equivalence` takes that flat 10 under `.tasks` too, because both modes then search the orders a run could have taken and that search grows multinomially in the sequence length.
    case commandLimit(Int)

    /// Controls iteration budgets for screening and random sampling. Defaults to `.standard` (200 screening rows, 200 random samplings).
    case budget(ExhaustBudget)

    /// Replays a specific test run using a fixed seed.
    ///
    /// Accepts a raw `UInt64` or a Crockford Base32 string.
    case replay(ReplaySeed)

    /// Silences issue reporting, log output, or both for this spec test run.
    ///
    /// Use `.suppress(.issueReporting)` when the run is expected to find a failing command sequence and the test asserts on the returned value. Use `.suppress(.logs)` to silence console output. Use `.suppress(.all)` for a completely silent run.
    case suppress(SuppressOption)

    /// Registers a closure that receives an ``ExhaustReport`` after the test completes.
    ///
    /// The report includes per-phase timing, invocation counts, and reduction statistics. Multiple `.onReport` closures are chained in order.
    case onReport((ExhaustReport) -> Void)

    /// Controls log verbosity for this spec test run.
    ///
    /// Defaults to `.log(.error)` when omitted, so only error-level messages appear.
    case log(LogLevel)

    /// Sets the number of concurrent execution lanes. Default is ``ConcurrencyLevel/two``.
    ///
    /// Each lane runs its assigned commands concurrently. For `.tasks` specs, the cooperative scheduler interleaves continuations at every `await` boundary. For `.threads` specs, each lane dispatches to a separate GCD thread.
    case parallelize(lanes: ConcurrencyLevel)

    /// Sets the maximum wall-clock time the drain loop waits with no pending continuations before declaring a timeout. Default is `.seconds(2)`. A value of `.zero` disables the timeout entirely, so the runner waits unbounded.
    ///
    /// A timed-out probe counts as a **pass**, not a failure. The timeout cannot tell a hung system apart from a contended machine, and treating it as a counterexample would let a loaded CI runner manufacture failures. The bound exists to stop a stalled probe wedging the process, not to detect hangs.
    ///
    /// This means a spec that deadlocks does not fail on that account alone. What surfaces instead is a runtime warning once timed-out probes reach a quarter of those attempted, reporting the rate. A system that hangs on only a few interleavings can stay under that threshold, so a green run with a nonzero timeout count is not evidence of liveness.
    case idleTimeout(TimeSpan)
}
