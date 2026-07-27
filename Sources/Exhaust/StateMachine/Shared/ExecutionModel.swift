/// Selects how a spec's commands run.
///
/// Pass one to `#execute`; the spec itself does not choose. One spec shape serves all three, so this is a dial rather than a rewrite:
///
/// ```swift
/// await #execute(CounterSpec.self)                  // one command at a time
/// await #execute(CounterSpec.self, mode: .tasks)    // interleaved at every await
/// await #execute(CounterSpec.self, mode: .threads)  // real OS threads
/// ```
///
/// What changes between them is which orders the commands can run in, and with it where a spec's claims can be judged. An `@Invariant` holds whatever order commands ran in, so it is checked wherever Exhaust has a settled state to check it against. An `@Equivalence` defines what "the same result" means when the order can vary, so a concurrent run is compared against a sequential replay and reported as a failure only when no valid order explains what the commands observed.
public enum ExecutionModel: Sendable {
    /// One command at a time, in the order generated.
    ///
    /// Invariants are checked after every command. The right choice for testing state-machine logic, and the only one for an `actor` spec, whose isolation serializes every command anyway. An equivalence is never consulted: with one order, "some valid order produces an equivalent result" is trivially the run itself.
    case sequential

    /// Concurrent Swift Tasks, interleaved deterministically at every `await` boundary.
    ///
    /// The interleaving is part of the generated input, so the same seed reproduces it and reduction minimizes the schedule alongside the commands. Invariants are checked whenever no command is mid-body, which is where a model and a system under test can be compared without reading a half-finished update. An equivalence is optional here, and declaring one turns the mode into a linearizability check.
    ///
    /// Reaches ordering bugs, reentrancy, and lost updates that straddle a suspension point. A race inside synchronous code has no suspension point to interleave at and needs ``threads``. Requires macOS 15, iOS 18, tvOS 18, watchOS 11, or visionOS 2, and async commands: a synchronous spec has nowhere to interleave, so it runs sequentially.
    case tasks

    /// Real OS threads, interleaved by the operating system.
    ///
    /// Reaches races inside synchronous primitives — locks, queues, atomics — that a task-based run steps over. The cost is determinism: the same seed does not reproduce the same interleaving, so detection relies on repetition and a reported counterexample can take several runs to reproduce.
    ///
    /// Every lane's commands run on one shared spec instance. The system under test is expected to defend itself, because that is the claim under test; any other spec state a command body touches must be thread-safe or absent. Invariants are judged in the sequential replays this mode already performs, not against the raced instance, whose state is one particular order's outcome and nothing has established that order was a valid one.
    ///
    /// Requires an `@Equivalence` and a reference-typed system under test, both reported at the start of the run.
    ///
    /// - Note: Unavailable under `#execute(time:)`, and writing it there is a compile-time error. Coverage novelty assumes an attempt's coverage follows from its command sequence, and preemptive scheduling makes it follow from an OS schedule the run can neither observe nor replay. Use ``tasks`` to search interleavings under a time budget.
    case threads
}

/// Selects how a spec's commands run under `#execute(time:)`, where only the deterministic modes are available.
///
/// Coverage-guided search assumes an attempt's coverage follows from its command sequence, so that a novel attempt means novel behavior rather than a lucky schedule. ``ExecutionModel/threads`` breaks that assumption on every attempt, and this type is why writing it here is a type error rather than something a run discovers.
public enum SearchableExecutionModel: Sendable {
    /// One command at a time, in the order generated. See ``ExecutionModel/sequential``.
    case sequential

    /// Concurrent Swift Tasks, interleaved deterministically at every `await` boundary. See ``ExecutionModel/tasks``.
    ///
    /// The interleaving is drawn as part of the generated input, so the search mutates and reduces the schedule alongside the commands, and an attempt's coverage still follows from its input.
    case tasks

    /// The mode a coverage-guided search cannot use.
    ///
    /// Present only so that writing it here explains itself. Nothing can construct it.
    @available(*, unavailable, message: "#execute(time:) cannot search mode: .threads. Coverage novelty assumes an attempt's coverage follows from its command sequence, and preemptive scheduling makes it follow from an OS schedule the run can neither observe nor replay, so novelty would reward scheduling luck instead of new behavior. Use mode: .tasks to search interleavings deterministically, or run this spec under plain #execute for repetition-based race detection.")
    case threads
}
