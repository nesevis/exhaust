import ExhaustCore

/// Records how closely an operation fixture corresponds to a public generator construction.
///
/// MetaGenerator recipe generation does not consult this metadata. It exists only to distinguish public regressions from package-level architectural findings after an oracle fires.
package enum MetaFuzzPublicConstruction: Sendable {
    /// The fixture's operation nesting and runtime shape can be expressed directly through the named public API.
    case direct(entryPoint: String)
    /// The named public API emits the operation, but adds packaging or a different runtime shape around the fixture's package-level representation.
    case operationEquivalent(entryPoint: String)
    /// No equivalent public construction is currently known.
    case packageOnly(reason: String)
}

/// Describes the operation-specific backward behavior that exact forward and reconstruction laws do not cover.
package enum MetaFuzzBackwardCapability: Sendable {
    /// Reflection may reject for type, range, branch, inverse, or downstream mismatches.
    case partial
    /// Reflection deliberately accepts any supplied target at this operation boundary.
    case permissive
    /// Reflection replaces context-owned evidence with a canonical value.
    case normalizing
    /// Reflection passes through the inner generator without applying the operation's forward-phase effect.
    case transparent
    /// Reflection uses a framework-authored inverse that the operation promises is exact.
    case exactInverse
    /// Reflection treats the original value as authoritative and does not validate derived copies.
    case originalOnly
}

/// Declares whether screening can extract and materialize choices from an operation fixture.
package enum MetaFuzzScreeningCapability: Sendable {
    /// Screening must analyze the fixture and materialize at least one row.
    case supported
    /// The fixture has no choice parameter for screening to vary.
    case parameterFree
    /// The fixture's choices are created by a dependent continuation that screening does not inspect.
    case dependentChoicesUnsupported
}

/// Collects the deliberate capability differences used to triage an operation-fixture finding.
///
/// Every fixture remains subject to exact forward, forward-with-witness, replay, exact materialization, guided materialization, and approximation-safety laws. These fields record only the backward and screening distinctions that make a universal parity assertion unsound.
package struct MetaFuzzInterpreterCapabilities: Sendable {
    package let backward: MetaFuzzBackwardCapability
    package let screening: MetaFuzzScreeningCapability
}

/// Names one deterministic recipe that reaches a generator operation during every successful execution.
package struct MetaFuzzOperationFixture: Sendable, CustomStringConvertible {
    package let name: String
    package let recipe: GenRecipe
    package let publicConstruction: MetaFuzzPublicConstruction
    package let interpreterCapabilities: MetaFuzzInterpreterCapabilities

    package var description: String {
        name
    }
}

/// Reports that a deterministic operation fixture could not reach its named operation through successful generation.
package struct MetaFuzzOperationCoverageViolation: Error, CustomStringConvertible {
    package let description: String
}

/// Reports that an approximate interpreter trapped, produced no value, or left the recipe's declared output type.
package struct MetaFuzzApproximationSafetyViolation: Error, CustomStringConvertible {
    package let description: String
}

/// Reports that screening could not analyze or coherently materialize an operation fixture according to its declared capability.
package struct MetaFuzzScreeningViolation: Error, CustomStringConvertible {
    package let description: String
}

/// Deterministic coverage spine for the operation laws exercised by the random MetaFuzz recipe walk.
package let metaFuzzOperationFixtures: [MetaFuzzOperationFixture] = [
    .init(
        name: "chooseBits",
        recipe: .leaf(.int(-10 ... 10)),
        publicConstruction: .direct(entryPoint: "ReflectiveGenerator.int(in:)"),
        interpreterCapabilities: .init(
            backward: .partial,
            screening: .supported
        )
    ),
    .init(
        name: "just",
        recipe: .leaf(.justInt(7)),
        publicConstruction: .direct(entryPoint: "ReflectiveGenerator.just(_:)"),
        interpreterCapabilities: .init(
            backward: .permissive,
            screening: .parameterFree
        )
    ),
    .init(
        name: "contramap",
        recipe: .combinator(.contramapped(.leaf(.int(-10 ... 10)), .increment)),
        publicConstruction: .operationEquivalent(entryPoint: "ReflectiveGenerator.result(success:failure:)"),
        interpreterCapabilities: .init(
            backward: .partial,
            screening: .supported
        )
    ),
    .init(
        name: "transform.map",
        recipe: .combinator(.mapped(.leaf(.int(-10 ... 10)), .increment)),
        publicConstruction: .direct(entryPoint: "ReflectiveGenerator.mapped(forward:backward:)"),
        interpreterCapabilities: .init(
            backward: .partial,
            screening: .supported
        )
    ),
    .init(
        name: "prune",
        recipe: .combinator(.pruned(.leaf(.int(-10 ... 10)))),
        publicConstruction: .operationEquivalent(entryPoint: "ReflectiveGenerator.data(prefix:)"),
        interpreterCapabilities: .init(
            backward: .partial,
            screening: .supported
        )
    ),
    .init(
        name: "pick",
        recipe: .combinator(.oneOf([
            .leaf(.justInt(1)),
            .leaf(.justInt(2)),
        ])),
        publicConstruction: .direct(entryPoint: "ReflectiveGenerator.oneOf(_:)"),
        interpreterCapabilities: .init(
            backward: .partial,
            screening: .supported
        )
    ),
    .init(
        name: "pick with continuation-composed branch",
        recipe: .combinator(.oneOf([
            .combinator(.boundRange(.leaf(.justInt(1)))),
        ])),
        publicConstruction: .direct(entryPoint: "ReflectiveGenerator.oneOf(_:) with bound(forward:backward:)"),
        interpreterCapabilities: .init(
            backward: .partial,
            screening: .supported
        )
    ),
    .init(
        name: "sequence",
        recipe: .combinator(.array(.leaf(.int(-10 ... 10)), lengthRange: 1 ... 2)),
        publicConstruction: .direct(entryPoint: "ReflectiveGenerator.array(length:)"),
        interpreterCapabilities: .init(
            backward: .partial,
            screening: .supported
        )
    ),
    .init(
        name: "zip",
        recipe: .combinator(.zipped(.leaf(.int(-10 ... 10)), .leaf(.int(-10 ... 10)))),
        publicConstruction: .operationEquivalent(entryPoint: "#gen(_:_:transform:)"),
        interpreterCapabilities: .init(
            backward: .partial,
            screening: .supported
        )
    ),
    .init(
        name: "getSize",
        recipe: .combinator(.getSized),
        publicConstruction: .direct(entryPoint: "ReflectiveGenerator.getSize(_:)"),
        interpreterCapabilities: .init(
            backward: .normalizing,
            screening: .dependentChoicesUnsupported
        )
    ),
    .init(
        name: "resize",
        recipe: .combinator(.resized(.leaf(.int(-10 ... 10)), size: 37)),
        publicConstruction: .direct(entryPoint: "ReflectiveGenerator.resize(_:)"),
        interpreterCapabilities: .init(
            backward: .partial,
            screening: .supported
        )
    ),
    .init(
        name: "filter",
        recipe: .combinator(.filtered(.leaf(.int(-20 ... 20)), .isEven)),
        publicConstruction: .direct(entryPoint: "ReflectiveGenerator.filter(_:_:)"),
        interpreterCapabilities: .init(
            backward: .transparent,
            screening: .supported
        )
    ),
    .init(
        name: "classify",
        recipe: .combinator(.classified(.leaf(.int(-10 ... 10)))),
        publicConstruction: .direct(entryPoint: "ReflectiveGenerator.classify(_:)"),
        interpreterCapabilities: .init(
            backward: .transparent,
            screening: .supported
        )
    ),
    .init(
        name: "unique",
        recipe: .combinator(.unique(.leaf(.int(-1000 ... 1000)))),
        publicConstruction: .direct(entryPoint: "ReflectiveGenerator.unique()"),
        interpreterCapabilities: .init(
            backward: .transparent,
            screening: .supported
        )
    ),
    .init(
        name: "transform.isomorph",
        recipe: .combinator(.isomorphed(.leaf(.int(-10 ... 10)), .increment)),
        publicConstruction: .operationEquivalent(entryPoint: "#gen(_:_:transform:)"),
        interpreterCapabilities: .init(
            backward: .exactInverse,
            screening: .supported
        )
    ),
    .init(
        name: "transform.bind",
        recipe: .combinator(.reifiedBind(.leaf(.int(-10 ... 10)))),
        publicConstruction: .direct(entryPoint: "ReflectiveGenerator.bound(forward:backward:)"),
        interpreterCapabilities: .init(
            backward: .partial,
            screening: .supported
        )
    ),
    .init(
        name: "transform.metamorphic",
        recipe: .combinator(.metamorphed(.leaf(.int(-10 ... 10)), .increment)),
        publicConstruction: .operationEquivalent(entryPoint: "ReflectiveGenerator.metamorph(_:)"),
        interpreterCapabilities: .init(
            backward: .originalOnly,
            screening: .supported
        )
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

    /// Checks that derivative and online approximation execute one operation fixture non-vacuously without changing its declared output type.
    static func checkApproximationFixture(
        _ fixture: MetaFuzzOperationFixture,
        seed: UInt64 = 42,
        samples: UInt64 = 16
    ) throws {
        let derivativeGenerator = buildGenerator(from: fixture.recipe)
        for sampleIndex in 0 ..< samples {
            var randomNumberGenerator = Xoshiro256.derive(
                from: seed,
                at: sampleIndex
            )
            do {
                guard let output = try CGSDerivativeInterpreter.sample(
                    derivativeGenerator,
                    using: &randomNumberGenerator,
                    size: 100
                ) else {
                    throw MetaFuzzApproximationSafetyViolation(
                        description: "derivative sampling produced no value for \(fixture.name)"
                    )
                }
                guard fixture.recipe.outputType.acceptsRuntimeOutput(output) else {
                    throw MetaFuzzApproximationSafetyViolation(
                        description: "derivative sampling produced \(type(of: output)), outside \(fixture.recipe.outputType), for \(fixture.name)"
                    )
                }
            } catch let violation as MetaFuzzApproximationSafetyViolation {
                throw violation
            } catch {
                throw MetaFuzzApproximationSafetyViolation(
                    description: "derivative sampling threw \(error) for \(fixture.name)"
                )
            }
        }

        var onlineInterpreter = OnlineCGSInterpreter(
            buildGenerator(from: fixture.recipe),
            predicate: { _ in false },
            sampleCount: 16,
            seed: seed,
            maxRuns: samples
        )
        var onlineSampleCount: UInt64 = 0
        do {
            while let output = try onlineInterpreter.next() {
                guard fixture.recipe.outputType.acceptsRuntimeOutput(output) else {
                    throw MetaFuzzApproximationSafetyViolation(
                        description: "online CGS produced \(type(of: output)), outside \(fixture.recipe.outputType), for \(fixture.name)"
                    )
                }
                onlineSampleCount += 1
            }
        } catch let violation as MetaFuzzApproximationSafetyViolation {
            throw violation
        } catch {
            throw MetaFuzzApproximationSafetyViolation(
                description: "online CGS threw \(error) for \(fixture.name)"
            )
        }
        guard onlineSampleCount == samples else {
            throw MetaFuzzApproximationSafetyViolation(
                description: "online CGS produced \(onlineSampleCount)/\(samples) values for \(fixture.name)"
            )
        }
    }

    /// Checks that screening analysis, row construction, guided materialization, and fresh-tree replay agree for one operation fixture.
    static func checkScreeningFixture(
        _ fixture: MetaFuzzOperationFixture,
        screeningBudget: UInt64 = 512
    ) throws {
        let generator = buildGenerator(from: fixture.recipe)
        let analysis = ChoiceTreeAnalysis.analyze(
            generator,
            compositeThreshold: screeningBudget
        )

        switch fixture.interpreterCapabilities.screening {
            case .supported:
                guard analysis != nil else {
                    throw MetaFuzzScreeningViolation(
                        description: "screening analysis returned nil for supported fixture \(fixture.name)"
                    )
                }
            case .parameterFree, .dependentChoicesUnsupported:
                guard analysis == nil else {
                    throw MetaFuzzScreeningViolation(
                        description: "screening analysis found parameters in unsupported fixture \(fixture.name)"
                    )
                }
        }

        var exampleCount = 0
        var firstViolation: MetaFuzzScreeningViolation?
        let result = ScreeningRunner.run(
            generator,
            screeningBudget: screeningBudget,
            property: { output in
                let outputIsValid = fixture.recipe.outputType.acceptsRuntimeOutput(output)
                if outputIsValid == false, firstViolation == nil {
                    firstViolation = MetaFuzzScreeningViolation(
                        description: "screening produced \(type(of: output)), outside \(fixture.recipe.outputType), for \(fixture.name)"
                    )
                }
                return outputIsValid
            },
            onExample: { output, tree, _ in
                exampleCount += 1
                guard firstViolation == nil else { return }
                do {
                    guard let replayed = try Interpreters.replay(generator, using: tree) else {
                        firstViolation = MetaFuzzScreeningViolation(
                            description: "fresh screening tree did not replay for \(fixture.name)"
                        )
                        return
                    }
                    guard anyEquals(replayed, output) else {
                        firstViolation = MetaFuzzScreeningViolation(
                            description: "fresh screening tree replayed \(replayed), not \(output), for \(fixture.name)"
                        )
                        return
                    }
                } catch {
                    firstViolation = MetaFuzzScreeningViolation(
                        description: "fresh screening tree replay threw \(error) for \(fixture.name)"
                    )
                }
            }
        )

        if let firstViolation {
            throw firstViolation
        }

        switch (fixture.interpreterCapabilities.screening, result) {
            case (.parameterFree, .notApplicable),
                 (.dependentChoicesUnsupported, .notApplicable):
                return
            case (.supported, .exhaustive), (.supported, .partial):
                guard exampleCount > 0 else {
                    throw MetaFuzzScreeningViolation(
                        description: "screening materialized no rows for supported fixture \(fixture.name)"
                    )
                }
            case (.supported, .failure):
                throw MetaFuzzScreeningViolation(
                    description: "screening reported a failure for supported fixture \(fixture.name)"
                )
            case (.supported, .notApplicable):
                throw MetaFuzzScreeningViolation(
                    description: "screening skipped supported fixture \(fixture.name)"
                )
            case (.parameterFree, _), (.dependentChoicesUnsupported, _):
                throw MetaFuzzScreeningViolation(
                    description: "screening did not skip unsupported fixture \(fixture.name)"
                )
        }
    }
}

private extension RecipeType {
    /// Returns whether an interpreter result retains the recipe's declared runtime shape.
    func acceptsRuntimeOutput(_ output: Any) -> Bool {
        switch self {
            case .int:
                output is Int
            case .bool:
                output is Bool
            case .double:
                output is Double
            case .string:
                output is String
            case .character:
                output is Character
            case let .arrayOf(elementType):
                Mirror(reflecting: output).displayStyle == .collection
                    && Mirror(reflecting: output).children.allSatisfy {
                        elementType.acceptsRuntimeOutput($0.value)
                    }
        }
    }
}
