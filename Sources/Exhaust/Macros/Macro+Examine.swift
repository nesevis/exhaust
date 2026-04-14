/// Validates a generator's reflection round-trip, replay determinism, and generation health, reporting failures as test issues.
///
/// ```swift
/// #examine(.int(in: 0...100))
/// #examine(personGen, samples: 500, seed: 42)
/// ```
///
/// - Parameters:
///   - gen: The generator to validate.
///   - samples: Number of values to generate and test. Defaults to 200.
///   - seed: Optional seed for deterministic validation runs.
/// - Returns: A ``ValidationReport`` summarizing the results.
import ExhaustCore

@freestanding(expression)
@discardableResult
public macro examine<T>(
    _ gen: ReflectiveGenerator<T>,
    samples: Int = 200,
    seed: UInt64? = nil
) -> ValidationReport = #externalMacro(module: "ExhaustMacros", type: "ExamineMacro")
