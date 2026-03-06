// Runs a feedback-guided property test on the given generator with directed hill climbing.
//
// Unlike `#exhaust` which performs a linear scan, `#explore` uses a seed pool
// with hill-climbing mutation to search the input space toward high-scorer regions.
//
// ## Trailing closure (source code captured)
// ```swift
// let counterexample = #explore(personGen, .maxIterations(10_000),
//     scorer: { Double($0.age) }
// ) { person in
//     person.age >= 0
// }
// ```
//
// ## Function reference (no source capture)
// ```swift
// let counterexample = #explore(personGen, .replay(42), scorer: scoreFn, property: isValid)
// ```
//
// - Returns: The shrunk counterexample if the property fails, or `nil` if all iterations pass.
import ExhaustCore

@freestanding(expression)
@discardableResult
public macro explore<T>(
    _ gen: ReflectiveGenerator<T>,
    _ settings: ExploreSettings...,
    scorer: (T) -> Double,
    property: (T) throws -> Bool,
) -> T? = #externalMacro(module: "ExhaustMacros", type: "ExploreMacro")
