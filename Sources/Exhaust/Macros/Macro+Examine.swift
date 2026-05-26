import ExhaustCore

/// Validates a generator's correctness and measures how well it explores its domain.
///
/// Use `#examine` to verify that a generator reflects and replays correctly, and to see whether it covers its numeric ranges, branches, sequence lengths, and character space. The returned ``ExamineReport`` exposes these metrics as assertable properties.
///
/// ```swift
/// // Quick health check — prints a coverage summary, fails on correctness errors:
/// #examine(personGen)
///
/// // Assert that the generator covers at least 7/10 deciles for every numeric type:
/// let report = #examine(personGen, .samples(500))
/// #expect(report.numericCoverage.allSatisfy { $0.decilesCovered >= 7 })
/// #expect(report.branchCoverage >= 0.9)
/// ```
///
/// Correctness checks (reflection round-trip, replay determinism, filter health) can fail the test. Coverage metrics never fail on their own — assert on ``ExamineReport`` properties to enforce quality thresholds.
///
/// - Parameters:
///   - gen: The generator to validate.
///   - settings: Variadic ``ExamineSettings`` controlling severity, sample count, seed, and output suppression.
/// - Returns: A ``ExamineReport`` with correctness results, coverage metrics, and a representative example of the generator's output structure.
@freestanding(expression)
@discardableResult
public macro examine<GeneratedValue>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    _ settings: ExamineSettings...
) -> ExamineReport = #externalMacro(module: "ExhaustMacros", type: "ExamineMacro")
