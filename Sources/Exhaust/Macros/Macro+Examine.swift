import ExhaustCore

/// Validates a generator's reflection round-trip, replay determinism, and generation health, reporting failures as test issues.
///
/// Pass ``ExamineSettings`` cases to control which checks run at which severity, the number of samples, and the replay seed:
/// ```swift
/// #examine(.int(in: 0...100))
/// #examine(personGen, .samples(500), .replay(42))
/// #examine(personGen, .reflection(.warning), .determinism(.error))
/// #examine(personGen, .severity(.silent))
/// ```
///
/// When no settings are provided, all checks run at ``ExamineSeverity/error`` severity with 200 samples and a random seed.
///
/// - Parameters:
///   - gen: The generator to validate.
///   - settings: Variadic ``ExamineSettings`` controlling severity, sample count, and seed.
/// - Returns: A ``ValidationReport`` summarizing the results.
@freestanding(expression)
@discardableResult
public macro examine<GeneratedValue>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    _ settings: ExamineSettings...
) -> ValidationReport = #externalMacro(module: "ExhaustMacros", type: "ExamineMacro")
