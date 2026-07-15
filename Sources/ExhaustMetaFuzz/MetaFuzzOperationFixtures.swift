import ExhaustCore

/// Names one deterministic recipe that reaches a generator operation during every successful execution.
package struct MetaFuzzOperationFixture: Sendable, CustomStringConvertible {
    package let name: String
    package let recipe: GenRecipe

    package var description: String {
        name
    }
}

/// Reports that a deterministic operation fixture could not reach its named operation through successful generation.
package struct MetaFuzzOperationCoverageViolation: Error, CustomStringConvertible {
    package let description: String
}

/// Deterministic coverage spine for the operation laws exercised by the random MetaFuzz recipe walk.
package let metaFuzzOperationFixtures: [MetaFuzzOperationFixture] = [
    .init(
        name: "chooseBits",
        recipe: .leaf(.int(-10 ... 10))
    ),
    .init(
        name: "just",
        recipe: .leaf(.justInt(7))
    ),
    .init(
        name: "contramap and transform.map",
        recipe: .combinator(.mapped(.leaf(.int(-10 ... 10)), .increment))
    ),
    .init(
        name: "prune",
        recipe: .combinator(.pruned(.leaf(.int(-10 ... 10))))
    ),
    .init(
        name: "pick",
        recipe: .combinator(.oneOf([
            .leaf(.justInt(1)),
            .leaf(.justInt(2)),
        ]))
    ),
    .init(
        name: "pick with continuation-composed branch",
        recipe: .combinator(.oneOf([
            .combinator(.boundRange(.leaf(.justInt(1)))),
        ]))
    ),
    .init(
        name: "sequence",
        recipe: .combinator(.array(.leaf(.int(-10 ... 10)), lengthRange: 1 ... 2))
    ),
    .init(
        name: "zip",
        recipe: .combinator(.zipped(.leaf(.int(-10 ... 10)), .leaf(.int(-10 ... 10))))
    ),
    .init(
        name: "getSize",
        recipe: .combinator(.getSized)
    ),
    .init(
        name: "resize",
        recipe: .combinator(.resized(.leaf(.int(-10 ... 10)), size: 37))
    ),
    .init(
        name: "filter",
        recipe: .combinator(.filtered(.leaf(.int(-20 ... 20)), .isEven))
    ),
    .init(
        name: "classify",
        recipe: .combinator(.classified(.leaf(.int(-10 ... 10))))
    ),
    .init(
        name: "unique",
        recipe: .combinator(.unique(.leaf(.int(-1000 ... 1000))))
    ),
    .init(
        name: "transform.isomorph",
        recipe: .combinator(.isomorphed(.leaf(.int(-10 ... 10)), .increment))
    ),
    .init(
        name: "transform.bind",
        recipe: .combinator(.reifiedBind(.leaf(.int(-10 ... 10))))
    ),
    .init(
        name: "transform.metamorphic",
        recipe: .combinator(.metamorphed(.leaf(.int(-10 ... 10)), .increment))
    ),
]

package extension MetaFuzz {
    /// Checks one deterministic operation fixture through the complete oracle roster after proving that it generates non-vacuously.
    static func checkOperationFixture(
        _ fixture: MetaFuzzOperationFixture,
        valueSeed: UInt64 = 42,
        perturbationSeed: UInt64 = 7
    ) throws {
        var interpreter = ValueAndChoiceTreeInterpreter(
            buildGenerator(from: fixture.recipe),
            seed: valueSeed,
            maxRuns: 1
        )
        do {
            guard try interpreter.next() != nil else {
                throw MetaFuzzOperationCoverageViolation(
                    description: "\(fixture.name) produced no value"
                )
            }
        } catch let violation as MetaFuzzOperationCoverageViolation {
            throw violation
        } catch {
            throw MetaFuzzOperationCoverageViolation(
                description: "\(fixture.name) failed generation with \(error)"
            )
        }

        try check(MetaFuzzCase(
            recipe: fixture.recipe,
            valueSeed: valueSeed,
            perturbationSeed: perturbationSeed
        ))
    }
}
