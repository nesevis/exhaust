// Configuration options for `#exhaust` property tests.
//
// Pass these as variadic arguments to `#exhaust` to control test behavior:
// ```swift
// #exhaust(personGen, .budget(.thorough)) { person in
//     person.age >= 0
// }
// ```
import ExhaustCore

/// Controls which outputs a test run silences.
///
/// Pass a single option to ``PropertySettings/suppress(_:)`` to disable issue reporting, log output, or both.
public enum SuppressOption: Sendable, Equatable {
    /// Suppresses `reportIssue()` calls for property failures. The test does not fail via the framework; the caller asserts on the returned value instead. Generation and internal errors are not suppressed — they signal a malfunction rather than the expected failure the caller is asserting on.
    case issueReporting
    /// Suppresses all log output to the console. Overrides any `.log(_:)` setting.
    case logs
    /// Suppresses both issue reporting and log output. The test run is silent except for generation and internal errors, which always surface.
    case all
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
    /// Use `.suppress(.issueReporting)` when the property test is expected to find a counterexample and the test asserts on the returned value rather than relying on the framework to record the failure. Use `.suppress(.logs)` to silence console output. Use `.suppress(.all)` to silence both. Generation and internal errors are always reported regardless of suppression — they indicate a malfunction, not the property failure being suppressed.
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
    /// Each lane runs an equal share of the sampling budget with an independently derived PRNG. Lanes race, and the first failure discovered cancels the others, so which counterexample is reported can depend on thread scheduling. The last lane absorbs any remainder from uneven division.
    ///
    /// Has no effect when combined with `.replay`.
    ///
    /// The ``ReflectiveGenerator/unique(fileID:line:column:)`` combinator deduplicates per-lane, not across lanes, so a parallel run can repeat a value between lanes.
    ///
    /// ```swift
    /// #exhaust(gen, .budget(.extensive), .parallelize(lanes: .two)) { value in
    ///     expensiveCheck(value)
    /// }
    /// ```
    case parallelize(lanes: ConcurrencyLevel)
}
