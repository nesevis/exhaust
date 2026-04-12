// Configuration options for `#exhaust` property tests.
//
// Pass these as variadic arguments to `#exhaust` to control test behavior:
// ```swift
// #exhaust(personGen, .budget(.expensive)) { person in
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

/// Controls the iteration budgets for coverage, random sampling, and reduction.
///
/// Three named presets cover common use cases. Use `.custom` for fine-grained control.
///
/// | Preset | Coverage | Sampling | Reduction |
/// |---|---|---|---|
/// | `.expedient` | 200 | 200 | `.fast` |
/// | `.expensive` | 500 | 500 | `.fast` |
/// | `.exorbitant` | 2000 | 2000 | `.slow` |
public enum ExhaustBudget: Sendable {
    /// 200 coverage rows, 200 random samplings, fast reduction. The default for property tests.
    case expedient
    /// 500 coverage rows, 500 random samplings, fast reduction. The default for contract tests.
    case expensive
    /// 2000 coverage rows, 2000 random samplings, slow reduction.
    case exorbitant
    /// Explicit values for all budget aspects.
    case custom(coverage: UInt64, sampling: UInt64, reduction: ReducerBudget)

    /// The iteration budget for structured coverage analysis.
    public var coverageBudget: UInt64 {
        switch self {
        case .expedient: 200
        case .expensive: 500
        case .exorbitant: 2000
        case let .custom(coverage, _, _): coverage
        }
    }

    /// The iteration budget for random sampling.
    public var samplingBudget: UInt64 {
        switch self {
        case .expedient: 200
        case .expensive: 500
        case .exorbitant: 2000
        case let .custom(_, sampling, _): sampling
        }
    }

    /// The test case reduction configuration.
    public var reducerBudget: ReducerBudget {
        switch self {
        case .expedient, .expensive: .fast
        case .exorbitant: .slow
        case let .custom(_, _, reduction): reduction
        }
    }
}


/// Configuration options for `#exhaust` property tests, passed as variadic arguments to control test behavior.
public enum ExhaustSettings<Output> {
    /// Controls iteration budgets for coverage, random sampling, and reduction. Defaults to `.expedient` (200 coverage rows, 200 random samplings, fast reduction).
    case budget(ExhaustBudget)

    /// A fixed seed for deterministic replay (reproduction, benchmarking, regression).
    ///
    /// Accepts a raw `UInt64` or a Crockford Base32 string:
    /// ```swift
    /// .replay(42)                // numeric
    /// .replay("3RT5GH8KM2")     // Crockford Base32
    /// ```
    case replay(ReplaySeed)

    /// Suppresses test-framework issue reporting (`reportIssue`) on failure.
    ///
    /// Use this when the property test is *expected* to find a counterexample and the test asserts on the returned value rather than relying on the framework to record the failure.
    case suppressIssueReporting

    /// Reflects an existing value through the generator and attempts to reduce it.
    ///
    /// Skips random generation entirely. The value is reflected into a choice tree and then reduced using the property as the test case reduction oracle.
    ///
    /// The value must fail the property — if it passes, an issue is reported.
    case reflecting(Output)

    /// Disables automatic structured coverage analysis.
    ///
    /// By default, `#exhaust` analyzes the generator's structure and selects a systematic coverage strategy: exhaustive enumeration for small finite domains, or greedy pairwise covering via the density method (Bryce & Colbourn 2009) for larger domains. This runs before random sampling and uses its own budget (see ``ExhaustBudget``).
    ///
    /// When `.randomOnly` is set, `#exhaust` skips this analysis and proceeds directly to random sampling. Useful for benchmarking, comparing coverage strategies, or when the analysis overhead is unwanted.
    case randomOnly

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

    /// Controls log verbosity and format for this test run.
    ///
    /// Defaults to `.logging(.error, .keyValue)` when omitted — only error-level messages appear.
    /// ```swift
    /// #exhaust(gen, .logging(.debug)) { value in ... }
    /// ```
    case logging(LogLevel, LogFormat = .keyValue)


}
