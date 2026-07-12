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

    /// Limits the maximum number of commands per generated sequence in `#execute(time:)` runs.
    ///
    /// When omitted, sequences carry up to 40 commands. Pass this when the default produces sequences too short to reach deep state (for example, a bounded data structure whose accumulation faults require capacity-many operations without interruption), or to shorten sequences when each command is expensive. Values below 1 are a configuration error.
    ///
    /// Only valid for `#execute(time:)`. Passing this setting to `#explore(time:)` is a configuration error because `#explore` has no command-sequence structure to limit.
    case commandLimit(Int)
}

// MARK: - Parsing

/// The fields the `time:` entry points read from their settings, extracted in one pass.
///
/// Both `#explore(time:)` and `#execute(time:)` parse through this type so field extraction cannot drift between the two modes; each entry point then validates the fields it does not support (`commandLimit` is an error on the value path) and applies the rest.
struct ParsedSprawlSettings {
    /// The replay seed, or nil when the run should draw a random one.
    var seed: UInt64?
    /// The configuration error for a replay seed that carries no run seed (screening-row seeds), rendered verbatim into the run's termination.
    var invalidReplayMessage: String?
    var suppressLogs = false
    var suppressIssueReporting = false
    var logLevel: LogLevel = .error
    /// The `#execute(time:)` per-sequence command cap; nil when unset. Present on the value path, it is a configuration error the caller reports.
    var commandLimit: Int?

    init(_ settings: [SprawlSettings]) {
        for setting in settings {
            switch setting {
                case let .replay(replaySeed):
                    // A screening-row replay resolves without a PRNG seed; a fuzz run replays the whole search from its root seed, so only seed-carrying replays apply here.
                    if let resolved = replaySeed.resolve(), let resolvedSeed = resolved.seed {
                        seed = resolvedSeed
                    } else {
                        invalidReplayMessage = "Invalid replay seed for #explore(time:): \(replaySeed). Pass the run seed from a prior report."
                    }
                case let .suppress(option):
                    if option == .logs || option == .all {
                        suppressLogs = true
                    }
                    if option == .issueReporting || option == .all {
                        suppressIssueReporting = true
                    }
                case let .log(level):
                    logLevel = level
                case let .commandLimit(limit):
                    commandLimit = limit
            }
        }
    }
}
