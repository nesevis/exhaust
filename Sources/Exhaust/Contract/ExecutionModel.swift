/// Selects the execution model a contract uses.
///
/// Pass one of these cases to `@Contract` at the declaration site:
///
/// ```swift
/// @Contract(.sequential)  // one command at a time, checked by @Invariant
/// @Contract(.tasks)       // cooperative interleaving at await, checked by @Invariant
/// @Contract(.threads)     // real OS threads, checked by @Oracle
/// ```
///
/// - `.sequential` runs commands one at a time and checks `@Invariant` after each step. The right choice for testing logic without concurrency. Required for `actor` contracts.
/// - `.tasks` runs commands concurrently with deterministic interleaving at every `await` boundary. The schedule is reproducible. Checks use `@Invariant` (and optionally `@Model`).
/// - `.threads` dispatches commands to real OS threads via GCD. The schedule is non-deterministic; bug detection relies on repetition. Checks use `@Oracle`, which compares the concurrent end state against a sequential replay.
public enum ExecutionModel: Sendable {
    /// Sequential execution, one command at a time.
    ///
    /// Commands run in order with `@Invariant` checked after each step. Use this for testing state-machine logic without concurrency. Required for `actor` contracts, because actor isolation serialises all dispatch.
    case sequential

    /// Cooperative concurrent scheduling of Swift Tasks.
    ///
    /// Interleavings happen at `await` suspension points only. The same seed always produces the same command ordering and lane assignment. Use this to find ordering bugs, reentrancy issues, and logical interleaving problems in async code.
    case tasks

    /// Preemptive concurrent scheduling on real OS threads.
    ///
    /// Commands run on GCD threads with non-deterministic interleaving. Use this to find data races, lock bugs, and dispatch queue issues that are invisible at `await` suspension points.
    case threads
}
