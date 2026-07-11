// Configuration options for `#explore(time:)` coverage-guided runs.
//
// Pass these as variadic arguments to `#explore(time:)` after the time budget:
// ```swift
// #explore(time: .minutes(15), .replay(42)) { message in
//     try Decoder.decode(message)
// }
// ```
import ExhaustCore

/// Controls test behavior for `#explore(time:)` coverage-guided runs, passed as variadic arguments.
///
/// The `time:` mode takes a distinct settings type from ``ExploreSettings`` because most of its knobs (replay of a whole fuzz run, budget-relative stopping) have no meaning under `directions:` mode, and the two modes are mutually exclusive at the type level.
///
/// - Important: This mode is experimental. Its settings, report format, and search behavior may change in any release; every call site emits a build warning until the mode stabilizes.
public enum SprawlSettings: Sendable {
    /// A fixed seed for deterministic replay (reproduction, benchmarking, regression).
    ///
    /// Accepts a raw `UInt64` or a Crockford Base32 string. Replay re-runs the whole search deterministically: the exploration loop is single-threaded and PRNG-driven, so the same seed visits the same attempts in the same order. Reduction runs concurrently, so the *order* in which clusters classify can differ between replays; the discovered clusters do not.
    case replay(ReplaySeed)

    /// Silences issue reporting, log output, or both for this run.
    ///
    /// Use `.suppress(.issueReporting)` when the run is expected to find failures and the test asserts on the returned ``SprawlReport`` instead. Generation and internal errors are not suppressed — they signal a malfunction rather than the failures the caller is asserting on.
    case suppress(SuppressOption)

    /// Controls log verbosity for this run.
    ///
    /// Defaults to `.log(.error)` when omitted — only error-level messages appear.
    case log(LogLevel)
}
