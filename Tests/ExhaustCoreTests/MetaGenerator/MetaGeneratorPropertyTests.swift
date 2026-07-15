import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Meta-Generator Property Tests", .tags(.dogfood))
struct MetaGeneratorPropertyTests {
    // MARK: 1. Reflection Round-Trip

    @Test("Generated generators round-trip through reflect and replay", arguments: metaRecipeTypes)
    func reflectionRoundTrip(type: RecipeType) throws {
        let tally = Tally()
        let badRecipe = try findMinimalCounterexample(recipeGenerator(producing: type, maxDepth: 2), maxIterations: 50) { recipe in
            guard recipe.nodeCount <= metaRecipeNodeBudget else {
                return true
            }
            let gen = buildGenerator(from: recipe)
            return checkAllValues(gen, maxRuns: 10, tally: tally) { value in
                guard let tree = try Interpreters.reflect(gen, with: value) else {
                    return nil
                }
                guard let replayed = try Interpreters.replay(gen, using: tree) else {
                    return nil
                }
                return anyEquals(value, replayed)
            }
        }
        #expect(badRecipe == nil, "Round-trip failed for minimal recipe: \(badRecipe!)")
        #expect(tally.evaluated > 0, "Round-trip sweep for \(type) reached no verdict: \(tally.summary)")
    }

    // MARK: 2. Materialize Agreement

    @Test("Materialize with flattened tree agrees with replay", arguments: metaRecipeTypes)
    func materializeAgreement(type: RecipeType) throws {
        let tally = Tally()
        let badRecipe = try findMinimalCounterexample(recipeGenerator(producing: type, maxDepth: 2), maxIterations: 50) { recipe in
            guard recipe.nodeCount <= metaRecipeNodeBudget else {
                return true
            }
            let gen = buildGenerator(from: recipe)
            return checkAllValues(gen, maxRuns: 10, tally: tally) { value in
                guard let reflectedTree = try Interpreters.reflect(gen, with: value) else {
                    return nil
                }
                guard let replayed = try Interpreters.replay(gen, using: reflectedTree) else {
                    return nil
                }
                let sequence = ChoiceSequence.flatten(reflectedTree)
                guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: reflectedTree) else {
                    return nil
                }
                return anyEquals(materialized, replayed)
            }
        }
        #expect(badRecipe == nil, "Materialize disagrees with replay for minimal recipe: \(badRecipe!)")
        #expect(tally.evaluated > 0, "Materialize sweep for \(type) reached no verdict: \(tally.summary)")
    }

    // MARK: 3. Reflect Stabilization

    @Test("Reflect stabilizes after one round for random recipes", arguments: metaRecipeTypes)
    func reflectStabilizes(type: RecipeType) throws {
        let tally = Tally()
        let badRecipe = try findMinimalCounterexample(recipeGenerator(producing: type, maxDepth: 2), maxIterations: 50) { recipe in
            guard recipe.nodeCount <= metaRecipeNodeBudget else {
                return true
            }
            let gen = buildGenerator(from: recipe)
            return checkAllValues(gen, maxRuns: 10, tally: tally) { value in
                guard let tree1 = try Interpreters.reflect(gen, with: value) else {
                    return nil
                }
                guard let replayed = try Interpreters.replay(gen, using: tree1) else {
                    return nil
                }
                guard let tree2 = try Interpreters.reflect(gen, with: replayed) else {
                    return nil
                }
                guard let replayed2 = try Interpreters.replay(gen, using: tree2) else {
                    return nil
                }
                return anyEquals(replayed, replayed2)
            }
        }
        #expect(badRecipe == nil, "Reflect did not stabilize for minimal recipe: \(badRecipe!)")
        #expect(tally.evaluated > 0, "Reflect-stabilization sweep for \(type) reached no verdict: \(tally.summary)")
    }

    // MARK: 4. Fast-Path Parity

    /// `nextValueOnly()` (the tree-free fast path, backed by ValueInterpreter) and `reproduceWithTree()` (the tree-building path) must produce the same value for the same run. This is the spec the sampling pipeline relies on; `reproduceFailureTree()` asserts it at runtime and falls back to `.just` when it breaks. Sweeping it over the recipe space checks it for every generator shape, not just the ones the pipeline happened to hit.
    ///
    /// Reached `unique` operations record their accepted decisions during the fast pass. Reproduction uses those decisions to repeat the same retry path without reinserting into the persistent deduplication history.
    @Test("Fast-path nextValueOnly agrees with reproduceWithTree for random recipes", arguments: metaRecipeTypes)
    func fastPathParity(type: RecipeType) throws {
        var recipeIter = ValueInterpreter(recipeGenerator(producing: type, maxDepth: 2), seed: 42, maxRuns: 30)
        var checkedRecipes = 0
        while let recipe = try recipeIter.next() {
            guard recipe.nodeCount <= metaRecipeNodeBudget else {
                continue
            }
            checkedRecipes += 1
            let gen = buildGenerator(from: recipe)
            var iter = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 5)
            while let valueOnly = try iter.nextValueOnly() {
                let reproduced = try iter.reproduceWithTree()
                #expect(reproduced != nil, "reproduceWithTree returned nil after nextValueOnly produced a value, recipe: \(recipe)")
                if let (reproducedValue, _) = reproduced {
                    #expect(
                        anyEquals(valueOnly, reproducedValue),
                        "Fast-path value \(valueOnly) disagrees with reproduced \(reproducedValue), recipe: \(recipe)"
                    )
                }
            }
        }
        #expect(checkedRecipes > 0, "The node budget must not exclude every recipe")
    }
}
