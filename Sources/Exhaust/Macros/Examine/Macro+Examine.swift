import ExhaustCore

/// Validates a generator's correctness and measures how well it explores its domain.
///
/// Use `#examine` to verify that a generator reflects correctly and to see whether it covers its numeric ranges, branches, sequence lengths, and character space. The returned ``ExamineReport`` exposes these metrics as assertable properties.
///
/// ```swift
/// // Quick health check — prints a coverage summary, fails on correctness errors:
/// #examine(personGen)
///
/// // Assert that the generator covers at least 7/10 deciles for every numeric type:
/// let report = #examine(personGen, .budget(500))
/// #expect(report.numericCoverage.allSatisfy { $0.decilesCovered >= 7 })
/// #expect(report.branchCoverage >= 0.9)
/// ```
///
/// Correctness checks (reflection round-trip, filter health) can fail the test. Coverage metrics never fail on their own — assert on ``ExamineReport`` properties to enforce quality thresholds. For replay determinism checking, use the overload with a trailing `replayCheck` closure.
///
/// - Parameters:
///   - gen: The generator to validate.
///   - settings: Variadic ``ExamineSettings`` controlling severity, sample budget, seed, and output suppression.
/// - Returns: An ``ExamineReport`` with correctness results, coverage metrics, and a representative example of the generator's output structure.
@freestanding(expression)
@discardableResult
public macro examine<GeneratedValue>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    _ settings: ExamineSettings...
) -> ExamineReport = #externalMacro(module: "ExhaustMacros", type: "ExamineMacro")

/// Validates a generator's correctness, measures domain coverage, and checks replay determinism under a user-provided equivalence.
///
/// The trailing closure receives two independently replayed values from the same choice tree. Return `true` when the values are equivalent under your domain's equality. A `false` return records a ``ExamineFailure/replayDivergence(sampleIndex:)`` failure, indicating that the generator or its output type introduces non-determinism that the framework cannot see (for example, a stored `UUID()` or a non-deterministic closure inside `.map`).
///
/// ```swift
/// #examine(personGen, .budget(200)) { lhs, rhs in
///     lhs.name == rhs.name && lhs.age == rhs.age
/// }
/// ```
///
/// - Parameters:
///   - gen: The generator to validate.
///   - settings: Variadic ``ExamineSettings`` controlling severity, sample budget, seed, and output suppression.
///   - replayCheck: Compares two replayed values for equivalence. Called once per sample with two independent replays of the same choice tree. Return `false` to record a divergence failure.
/// - Returns: An ``ExamineReport`` with correctness results, replay determinism counts, and coverage metrics.
@freestanding(expression)
@discardableResult
public macro examine<GeneratedValue>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    _ settings: ExamineSettings...,
    replayCheck: @Sendable (GeneratedValue, GeneratedValue) -> Bool
) -> ExamineReport = #externalMacro(module: "ExhaustMacros", type: "ExamineMacro")
