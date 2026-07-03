// Configuration options for `#explore` classification-aware property tests.
//
// Pass these as variadic arguments to `#explore` to control test behavior:
// ```swift
// let report = #explore(crossingGen, .budget(.thorough),
//     directions: [
//         ("northward", { $0.from > 0 && $0.to < 0 }),
//         ("southward", { $0.from < 0 && $0.to > 0 }),
//     ]
// ) { value in
//     flightController.updatePosition(value)
//     #expect(flightController.heading.isValid)
// }
// ```
import ExhaustCore

/// Controls test behavior for `#explore` classification tests, passed as variadic arguments.
public enum ExploreSettings: Sendable {
    /// Controls per-direction hit targets and attempt budgets. Defaults to `.standard` (30 hits per direction, 300 max attempts per direction). See ``ExhaustBudget`` for the per-preset explore interpretation.
    case budget(ExhaustBudget)

    /// A fixed seed for deterministic replay (reproduction, benchmarking, regression).
    ///
    /// Accepts a raw `UInt64` or a Crockford Base32 string.
    case replay(ReplaySeed)

    /// Silences issue reporting, log output, or both for this explore run.
    ///
    /// Use `.suppress(.issueReporting)` when the explore run is expected to find a counterexample and the test asserts on the returned value. Use `.suppress(.logs)` to silence console output. Use `.suppress(.all)` for a completely silent run.
    case suppress(SuppressOption)

    /// Controls log verbosity for this explore run.
    ///
    /// Defaults to `.log(.error)` when omitted — only error-level messages appear.
    case log(LogLevel)

    /// Runs per-direction tuning passes in parallel, one GCD lane per direction.
    ///
    /// Skips the warm-up phase (each direction's CGS tuning provides its own online warm-up) and gives each direction a fixed allocation of `maxAttemptsPerDirection` samples. Disabled when combined with `.replay` (replay forces sequential execution for deterministic reproduction).
    ///
    /// When parallelized, different runs with the same seed may surface different counterexamples because GCD thread scheduling is non-deterministic. Replay of a specific seed is always deterministic.
    case parallelize
}
