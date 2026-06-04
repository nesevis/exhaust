/// Selects the concurrency mechanism a contract uses.
///
/// Pass one of these cases to `@Contract` at the declaration site:
///
/// ```swift
/// @Contract(.tasks)    // cooperative: deterministic interleaving of Swift Tasks
/// @Contract(.threads)  // preemptive: real OS threads, finds data races
/// ```
///
/// - `.tasks` interleaves Swift Tasks cooperatively at every `await` boundary. The schedule is deterministic and reproducible. Checks use `@Invariant` (and optionally `@Model`).
/// - `.threads` dispatches commands to real OS threads via GCD. The schedule is non-deterministic; bug detection relies on repetition. Checks use `@Oracle`, which compares the concurrent end state against a sequential replay.
public enum ConcurrencyModel: Sendable {
    /// Cooperative scheduling of Swift Tasks.
    ///
    /// Interleavings happen at `await` suspension points only. The same seed always produces the same command ordering and lane assignment. Use this to find ordering bugs, reentrancy issues, and logical interleaving problems.
    case tasks

    /// Preemptive scheduling on real OS threads.
    ///
    /// Commands run on GCD threads with non-deterministic interleaving. Use this to find data races, lock bugs, and dispatch queue issues that are invisible at `await` suspension points.
    case threads
}
