/// Selects the execution model a spec uses.
///
/// Pass one of these cases to `@StateMachine` at the declaration site:
///
/// ```swift
/// @StateMachine(.sequential)  // one command at a time, checked by @Invariant
/// @StateMachine(.tasks)       // cooperative interleaving at await, checked by @Invariant
/// @StateMachine(.threads)     // real OS threads, checked by @Oracle
/// ```
///
/// - `.sequential` runs commands one at a time and checks `@Invariant` after each step. The right choice for testing logic without concurrency. Required for `actor` specs.
/// - `.tasks` runs commands concurrently with deterministic interleaving at every `await` boundary. The schedule is reproducible. Checks use `@Invariant`.
/// - `.threads` dispatches commands to real OS threads via GCD. The schedule is non-deterministic; bug detection relies on repetition. Checks use `@Oracle`, which compares the concurrent end state against a sequential replay.
public enum ExecutionModel: Sendable {
    /// Sequential execution, one command at a time.
    ///
    /// Commands run in order with `@Invariant` checked after each step. Use this for testing state-machine logic without concurrency. Required for `actor` specs, because actor isolation serializes all dispatch.
    case sequential

    /// Cooperative concurrent scheduling of Swift Tasks.
    ///
    /// Interleavings happen at `await` suspension points only. The same seed always produces the same command ordering and lane assignment. Use this to find ordering bugs, reentrancy issues, and logical interleaving problems in async code.
    case tasks

    /// Preemptive concurrent scheduling on real OS threads.
    ///
    /// Commands run on GCD threads with non-deterministic interleaving. Use this to find data races, lock bugs, and dispatch queue issues that are invisible at `await` suspension points.
    ///
    /// - Note: `.threads` specs run under plain `#execute` only. `#execute(time:)` refuses them: coverage novelty assumes an attempt's coverage is determined by its command sequence, and preemptive scheduling breaks that assumption on every attempt. Use `.tasks` to search interleavings under a time budget.
    case threads
}
