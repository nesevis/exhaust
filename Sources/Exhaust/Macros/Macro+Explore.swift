/// Runs a feedback-guided property test on a generator, using directed hill climbing to search toward high-scoring regions of the input space.
///
/// Unlike ``#exhaust(_:_:property:)``, which samples the input space uniformly, `#explore` maintains a seed pool and mutates inputs toward regions where the scorer function returns higher values, making it effective for finding edge cases in monotone properties.
///
/// Pass the property as a trailing closure to capture source location for better failure messages:
///
/// ```swift
/// let counterexample = #explore(personGen, .samplingBudget(10_000),
///     scorer: { Double($0.age) }
/// ) { person in
///     person.age >= 0
/// }
/// ```
///
/// Or pass a function reference when source capture is not needed:
///
/// ```swift
/// let counterexample = #explore(personGen, .replay(42), scorer: scoreFn, property: isValid)
/// ```
///
/// - Returns: The reduced counterexample if the property fails, or `nil` if all iterations pass.
import ExhaustCore

@freestanding(expression)
@discardableResult
public macro explore<GeneratedValue>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    _ settings: ExploreSettings...,
    scorer: (GeneratedValue) -> Double,
    property: (GeneratedValue) throws -> Bool
) -> GeneratedValue? = #externalMacro(module: "ExhaustMacros", type: "ExploreMacro")
