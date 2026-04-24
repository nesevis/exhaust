// Configuration options for `#explore` classification-aware property tests.
//
// Pass these as variadic arguments to `#explore` to control test behavior:
// ```swift
// let report = #explore(crossingGen, .budget(.expensive),
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
/// Three named presets cover common use cases. Use `.custom` for fine-grained control.
///
/// | Preset | K (hits per direction) | Max attempts per direction |
/// |---|---|---|
/// | `.expedient` | 30 | 300 |
/// | `.expensive` | 100 | 1000 |
/// | `.exorbitant` | 300 | 3000 |
public enum ExploreBudget: Sendable {
    /// 30 hits per direction, 300 max attempts per direction. The default for exploration tests.
    case expedient
    /// 100 hits per direction, 1000 max attempts per direction.
    case expensive
    /// 300 hits per direction, 3000 max attempts per direction.
    case exorbitant
    /// Explicit values for both budget aspects.
    case custom(hitsPerDirection: Int, maxAttemptsPerDirection: Int)

    /// The number of matching samples each direction must accumulate before it is considered covered.
    public var hitsPerDirection: Int {
        switch self {
        case .expedient: 30
        case .expensive: 100
        case .exorbitant: 300
        case let .custom(hitsPerDirection, _): hitsPerDirection
        }
    }

    /// The per-direction contribution to the shared attempt pool.
    public var maxAttemptsPerDirection: Int {
        switch self {
        case .expedient: 300
        case .expensive: 1000
        case .exorbitant: 3000
        case let .custom(_, maxAttemptsPerDirection): maxAttemptsPerDirection
        }
    }
}

/// Configuration options for `#explore` classification-aware property tests, passed as variadic arguments to control test behavior.
public enum ExploreSettings: Sendable {
    /// Controls per-direction hit targets and attempt budgets. Defaults to `.expedient` (30 hits per direction, 300 max attempts per direction).
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
