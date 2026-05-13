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

/// Controls the per-direction hit target and attempt budget for `#explore`.
///
/// | Preset | K (hits per direction) | Max attempts per direction |
/// |---|---|---|
/// | `.quick` | 10 | 100 |
/// | `.standard` | 30 | 300 |
/// | `.thorough` | 100 | 1000 |
/// | `.extensive` | 300 | 3000 |
///
/// Use `.standard` (the default) when 30 hits per direction is enough to confirm reachability. Use `.quick` for a fast smoke test. Use `.thorough` when direction predicates are sparse (less than 10 percent acceptance rate) and need more attempts to accumulate hits. Use `.extensive` for statistical coverage reporting where confidence intervals matter.
public enum ExploreBudget: Sendable {
    /// 10 hits, 100 max attempts per direction.
    case quick
    /// 30 hits, 300 max attempts per direction.
    case standard
    /// 100 hits, 1000 max attempts per direction.
    case thorough
    /// 300 hits, 3000 max attempts per direction.
    case extensive
    /// Explicit values for both budget aspects.
    case custom(hitsPerDirection: Int, maxAttemptsPerDirection: Int)

    /// The number of matching samples each direction must accumulate before it is considered covered.
    public var hitsPerDirection: Int {
        switch self {
        case .quick: 10
        case .standard: 30
        case .thorough: 100
        case .extensive: 300
        case let .custom(hitsPerDirection, _): hitsPerDirection
        }
    }

    /// The per-direction contribution to the shared attempt pool.
    public var maxAttemptsPerDirection: Int {
        switch self {
        case .quick: 100
        case .standard: 300
        case .thorough: 1000
        case .extensive: 3000
        case let .custom(_, maxAttemptsPerDirection): maxAttemptsPerDirection
        }
    }
}

/// Controls test behavior for `#explore` classification tests, passed as variadic arguments.
public enum ExploreSettings: Sendable {
    /// Controls per-direction hit targets and attempt budgets. Defaults to `.standard` (30 hits per direction, 300 max attempts per direction).
    case budget(ExploreBudget)

    /// A fixed seed for deterministic replay (reproduction, benchmarking, regression).
    ///
    /// Accepts a raw `UInt64` or a Crockford Base32 string.
    case replay(ReplaySeed)

    /// Silences issue reporting, log output, or both for this explore run.
    ///
    /// Use `.suppress(.issueReporting)` when the explore run is expected to find a counterexample and the test asserts on the returned value. Use `.suppress(.logs)` to silence console output. Use `.suppress(.all)` for a completely silent run.
    case suppress(SuppressOption)

    /// Controls log verbosity and format for this explore run.
    ///
    /// Defaults to `.logging(.error, .keyValue)` when omitted — only error-level messages appear.
    case logging(LogLevel, LogFormat = .keyValue)
}
