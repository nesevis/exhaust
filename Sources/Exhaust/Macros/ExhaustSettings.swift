// Configuration options for `#exhaust` property tests.
//
// Pass these as variadic arguments to `#exhaust` to control test behavior:
// ```swift
// #exhaust(personGen, .budget(.thorough)) { person in
//     person.age >= 0
// }
// ```
import ExhaustCore

/// A replay seed for deterministic reproduction, accepting either a raw `UInt64` or a Crockford Base32 string.
///
/// ```swift
/// .replay(42)                // UInt64 literal
/// .replay("3RT5GH8KM2")     // Crockford Base32
/// ```
public enum ReplaySeed: Sendable {
    /// A raw numeric seed.
    case numeric(UInt64)
    /// A Crockford Base32 encoded seed string.
    case encoded(String)

    /// Resolves the seed to a `UInt64` value.
    ///
    /// - Returns: The numeric seed, or `nil` if the encoded string is invalid.
    public func resolve() -> UInt64? {
        switch self {
        case let .numeric(value):
            value
        case let .encoded(string):
            CrockfordBase32.decode(string)
        }
    }
}

extension ReplaySeed: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) {
        self = .numeric(value)
    }
}

extension ReplaySeed: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .encoded(value)
    }
}

/// Controls which outputs a test run silences.
///
/// Pass a single option to ``PropertySettings/suppress(_:)`` to disable issue reporting, log output, or both.
public enum SuppressOption: Sendable, Equatable {
    /// Suppresses `reportIssue()` calls on failure. The test does not fail via the framework; the caller asserts on the returned value instead.
    case issueReporting
    /// Suppresses all log output to the console. Overrides any `.log(_:)` setting.
    case logs
    /// Suppresses both issue reporting and log output. The test run is completely silent.
    case all
}

/// Controls the iteration budgets for coverage and random sampling.
///
/// | Preset | Coverage | Sampling |
/// |---|---|---|
/// | `.quick` | 100 | 100 |
/// | `.standard` | 200 | 200 |
/// | `.thorough` | 600 | 600 |
/// | `.extensive` | 2000 | 2000 |
///
/// Use `.standard` (the default) for development — sufficient for generators with fewer than 50 independent parameters. Use `.quick` when iteration speed matters more than coverage depth. Use `.thorough` when the generator has high combinatorial complexity (many picks, nested sequences) and you want stronger coverage guarantees. Use `.extensive` when counterexamples are rare or you want broad coverage; expect roughly 10x the runtime of `.standard`.
///
/// Scale any preset with arithmetic: `.thorough * 3` produces a custom budget of 1800/1800, and `.standard / 2` produces 100/100.
public enum ExhaustBudget: Sendable {
    /// Faster than default. Use when iteration speed matters more than coverage depth.
    case quick
    /// Default for property tests and contract tests. Sufficient for most generators during development.
    case standard
    /// Stronger coverage for complex generators.
    case thorough
    /// Broad coverage at 10x the cost of `.standard`.
    case extensive
    /// Explicit values for all budget aspects.
    case custom(coverage: UInt64, sampling: UInt64)

    /// The iteration budget for structured coverage analysis.
    public var coverageBudget: UInt64 {
        switch self {
        case .quick: 100
        case .standard: 200
        case .thorough: 600
        case .extensive: 2000
        case let .custom(coverage, _): coverage
        }
    }

    /// The iteration budget for random sampling.
    public var samplingBudget: UInt64 {
        switch self {
        case .quick: 100
        case .standard: 200
        case .thorough: 600
        case .extensive: 2000
        case let .custom(_, sampling):
            sampling
        }
    }

    /// Scales both coverage and sampling budgets by a multiplier.
    public static func * (lhs: ExhaustBudget, rhs: UInt64) -> ExhaustBudget {
        precondition(rhs > 0, "Multiplier must be positive")
        return .custom(
            coverage: lhs.coverageBudget * rhs,
            sampling: lhs.samplingBudget * rhs
        )
    }

    /// Scales both coverage and sampling budgets by a multiplier.
    public static func * (lhs: UInt64, rhs: ExhaustBudget) -> ExhaustBudget {
        rhs * lhs
    }

    /// Divides both coverage and sampling budgets by a divisor, flooring at 1.
    public static func / (lhs: ExhaustBudget, rhs: UInt64) -> ExhaustBudget {
        precondition(rhs > 0, "Divisor must be positive")
        return .custom(
            coverage: max(1, lhs.coverageBudget / rhs),
            sampling: max(1, lhs.samplingBudget / rhs)
        )
    }
}

/// Controls test behavior for `#exhaust` property tests, passed as variadic arguments.
public enum PropertySettings {
    /// Controls iteration budgets for coverage and random sampling. Defaults to `.standard` (200 coverage rows, 200 random samplings).
    case budget(ExhaustBudget)

    /// A fixed seed for deterministic replay (reproduction, benchmarking, regression).
    ///
    /// Accepts a raw `UInt64` or a Crockford Base32 string:
    /// ```swift
    /// .replay(42)                // numeric
    /// .replay("3RT5GH8KM2")     // Crockford Base32
    /// ```
    case replay(ReplaySeed)

    /// Silences issue reporting, log output, or both for this test run.
    ///
    /// Use `.suppress(.issueReporting)` when the property test is expected to find a counterexample and the test asserts on the returned value rather than relying on the framework to record the failure. Use `.suppress(.logs)` to silence console output. Use `.suppress(.all)` for a completely silent run.
    case suppress(SuppressOption)
    /// Prints the choice tree before and after reduction as a bottom-up Unicode visualization.
    case visualize

    /// Registers a closure that receives an ``ExhaustReport`` with run statistics after the test completes.
    ///
    /// The closure fires synchronously before `#exhaust` returns, on every exit path (pass, fail, error, reflecting). Not `@Sendable` — executes on the calling task.
    case onReport((ExhaustReport) -> Void)

    /// Collects per-example statistics in the OpenPBTStats JSON Lines format and attaches the result to the test run.
    ///
    /// Each test example produces one JSON line with status, a `customDump` representation, and complexity features derived from the choice tree. The accumulated JSONL is recorded as a test attachment (Swift Testing `Attachment` or XCTest `XCTAttachment`) when the test completes.
    ///
    /// Compatible with the [Tyche](https://github.com/tyche-pbt/tyche-extension) visualization tool.
    case collectOpenPBTStats

    /// Includes a structural diff between the original failing value and the reduced counterexample in the failure output.
    ///
    /// Off by default because the diff computation is expensive for large values. Enable when diagnosing what the reducer changed.
    case includeDiff

    /// Controls log verbosity for this test run.
    ///
    /// Defaults to `.log(.error)` when omitted — only error-level messages appear.
    /// ```swift
    /// #exhaust(gen, .log(.debug)) { value in ... }
    /// ```
    case log(LogLevel)

    /// Splits the random sampling phase across the given number of parallel GCD lanes.
    ///
    /// On fast generators there is very little benefit in going above two.
    ///
    /// Each lane runs an equal share of the sampling budget with an independently derived PRNG, so the same seed produces the same counterexample regardless of thread scheduling. The last lane absorbs any remainder from uneven division.
    ///
    /// Has no effect when combined with `.replay`.
    ///
    /// Uniqueness deduplication (`.unique`) is enforced per-lane, not across lanes.
    ///
    /// ```swift
    /// #exhaust(gen, .budget(.extensive), .parallel(2)) { value in
    ///     expensiveCheck(value)
    /// }
    /// ```
    case parallel(UInt8)
}
