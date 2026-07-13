//
//  MetaFuzzCase.swift
//  ExhaustMetaFuzz
//
//  The generated value for self-fuzzing runs: a generator recipe plus the seeds that make one pipeline evaluation deterministic.
//

import ExhaustCore

/// One self-fuzzing attempt: a generator recipe plus the seeds that make its pipeline evaluation deterministic.
///
/// Opaque outside the package by design — the harness passes cases from ``MetaFuzz/caseGenerator(maxDepth:nodeBudget:)`` to ``MetaFuzz/check(_:)`` without inspecting them, so the recipe language stays free to evolve. The description renders the recipe and seeds, which is what fault-inventory clusters and frozen reproducers show.
public struct MetaFuzzCase: Sendable, CustomStringConvertible {
    package let recipe: GenRecipe
    package let valueSeed: UInt64
    package let perturbationSeed: UInt64

    package init(recipe: GenRecipe, valueSeed: UInt64, perturbationSeed: UInt64) {
        self.recipe = recipe
        self.valueSeed = valueSeed
        self.perturbationSeed = perturbationSeed
    }

    public var description: String {
        "MetaFuzzCase(recipe: \(recipe), valueSeed: \(valueSeed), perturbationSeed: \(perturbationSeed))"
    }
}

/// Entry points for fuzzing Exhaust's own pipeline: the case generator and the oracle check.
public enum MetaFuzz {
    /// Output types the case generator sweeps over — every type the recipe language can produce.
    package static let sweptTypes: [RecipeType] = [.int, .bool, .double, .string, .character, .arrayOf(.int)]

    /// Generates fuzz cases: a well-typed recipe within the node budget, plus value and perturbation seeds.
    ///
    /// Mutating a case's choice sequence is structural mutation of the recipe — the fuzzing mode's medium band deletes, duplicates, and replaces combinator layers directly.
    ///
    /// - Parameters:
    ///   - maxDepth: Combinator nesting ceiling handed to the recipe generator.
    ///   - nodeBudget: Recipe node-count ceiling, enforced by rejection. Deep recipes overflow the 512 KiB test-thread stack in debug builds, so raise this only where the evaluating thread's stack size is known — an executable probe's main thread, for example. Calibrate raises with `ExhaustStackProbe`.
    public static func caseGenerator(maxDepth: Int = 2, nodeBudget: Int = 40) -> ReflectiveGenerator<MetaFuzzCase> {
        let recipes = Gen.filter(
            Gen.pick(choices: sweptTypes.map { type in
                (1, recipeGenerator(producing: type, maxDepth: maxDepth))
            }),
            type: .rejectionSampling,
            predicate: { recipe in recipe.nodeCount <= nodeBudget },
            sourceLocation: FilterSourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
        )
        let seeds = Gen.choose(in: UInt64.min ... UInt64.max)
        let cases = recipes.bind { recipe in
            seeds.bind { valueSeed in
                seeds.map { perturbationSeed in
                    MetaFuzzCase(recipe: recipe, valueSeed: valueSeed, perturbationSeed: perturbationSeed)
                }
            }
        }
        return ReflectiveGenerator(cases)
    }
}
