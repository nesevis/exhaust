import ExhaustCore
import ExhaustTestSupport
import Testing

extension MetaGeneratorPropertyTests {
    // MARK: 8. Reduction Preserves Failure (manual — circular if dogfooded)

    @Test("Reduced values still fail the original property", arguments: metaRecipeTypes)
    func reductionPreservesFailure(type: RecipeType) throws {
        let recipeGen = recipeGenerator(producing: type, maxDepth: 1)
        var recipeIter = ValueInterpreter(recipeGen, seed: 42, maxRuns: 20)
        let property = failingProperty(for: type)
        var checkedRecipes = 0
        while let recipe = try recipeIter.next() {
            guard recipe.nodeCount <= metaRecipeNodeBudget else {
                continue
            }
            checkedRecipes += 1
            let gen = buildGenerator(from: recipe)

            var valueIter = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 20)
            while let (value, tree) = try valueIter.next() {
                guard property(value) == false else {
                    continue
                }
                guard case let .reduced(_, _, shrunk) = try? Interpreters.choiceGraphReduce(
                    gen: gen, tree: tree, config: .init(maxStalls: 2), property: property
                ) else {
                    continue
                }
                #expect(
                    property(shrunk) == false,
                    "Shrunk value passes property but shouldn't, recipe: \(recipe)"
                )
            }
        }
        #expect(checkedRecipes > 0, "The node budget must not exclude every recipe")
    }

    // MARK: 8b. Reduction Reduces Complexity

    @Test("Reduced choice sequence shortlex-precedes or equals the original", arguments: metaRecipeTypes)
    func reductionReducesComplexity(type: RecipeType) throws {
        let recipeGen = recipeGenerator(producing: type, maxDepth: 1)
        var recipeIter = ValueInterpreter(recipeGen, seed: 42, maxRuns: 20)
        let property = failingProperty(for: type)
        var checkedRecipes = 0
        while let recipe = try recipeIter.next() {
            guard recipe.nodeCount <= metaRecipeNodeBudget else {
                continue
            }
            checkedRecipes += 1
            let gen = buildGenerator(from: recipe)

            var valueIter = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 20)
            while let (value, tree) = try valueIter.next() {
                guard property(value) == false else {
                    continue
                }
                let originalSequence = ChoiceSequence.flatten(tree)
                guard case let .reduced(shrunkSequence, _, _) = try? Interpreters.choiceGraphReduce(
                    gen: gen, tree: tree, config: .init(maxStalls: 2), property: property
                ) else {
                    continue
                }
                #expect(
                    shrunkSequence.shortLexPrecedes(originalSequence) || shrunkSequence == originalSequence,
                    "Shrunk sequence is not simpler than the original, recipe: \(recipe)"
                )
            }
        }
        #expect(checkedRecipes > 0, "The node budget must not exclude every recipe")
    }

    // MARK: 21. Closed-loop reduction

    /// The choice sequence the reducer reports, materialized in `.exact` mode, must produce exactly the shrunk value the reducer reports. This ties the reducer's sequence accounting to its output value.
    @Test("Reduced sequence materializes to the reported shrunk value", arguments: metaRecipeTypes)
    func reductionClosedLoop(type: RecipeType) throws {
        let recipeGen = recipeGenerator(producing: type, maxDepth: 1)
        var recipeIter = ValueInterpreter(recipeGen, seed: 42, maxRuns: 20)
        let property = failingProperty(for: type)
        var checkedRecipes = 0
        while let recipe = try recipeIter.next() {
            guard recipe.nodeCount <= metaRecipeNodeBudget else {
                continue
            }
            checkedRecipes += 1
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 20)
            while let (value, tree) = try valueIter.next() {
                guard property(value) == false else {
                    continue
                }
                guard case let .reduced(sequence, reducedTree, shrunk) = try? Interpreters.choiceGraphReduce(
                    gen: gen, tree: tree, config: .init(maxStalls: 2), property: property
                ) else {
                    continue
                }
                guard case let .success(materialized, _, _) = Materializer.materialize(
                    gen, prefix: sequence, mode: .exact, fallbackTree: reducedTree
                ) else {
                    Issue.record("Reduced sequence failed to materialize for recipe: \(recipe)")
                    continue
                }
                #expect(
                    anyEquals(materialized, shrunk),
                    "Reduced sequence materialized to \(materialized), not the reported shrunk value \(shrunk), recipe: \(recipe)"
                )
            }
        }
        #expect(checkedRecipes > 0, "The node budget must not exclude every recipe")
    }

    // MARK: 22. Reduction monotonicity

    /// Re-reducing an already-reduced tree must never produce a shortlex-larger sequence — reduction only ever shrinks. A budgeted reducer (`maxStalls: 2`) need not fully converge in one pass, so a smaller second result is legal; a larger one is a defect (an encoder that grew a reduced input).
    @Test("Re-reducing never enlarges the sequence", arguments: metaRecipeTypes)
    func reductionMonotonicity(type: RecipeType) throws {
        let recipeGen = recipeGenerator(producing: type, maxDepth: 1)
        var recipeIter = ValueInterpreter(recipeGen, seed: 42, maxRuns: 20)
        let property = failingProperty(for: type)
        var checkedRecipes = 0
        while let recipe = try recipeIter.next() {
            guard recipe.nodeCount <= metaRecipeNodeBudget else {
                continue
            }
            checkedRecipes += 1
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 20)
            while let (value, tree) = try valueIter.next() {
                guard property(value) == false else {
                    continue
                }
                guard case let .reduced(firstSequence, firstTree, _) = try? Interpreters.choiceGraphReduce(
                    gen: gen, tree: tree, config: .init(maxStalls: 2), property: property
                ) else {
                    continue
                }
                guard case let .reduced(secondSequence, _, _) = try? Interpreters.choiceGraphReduce(
                    gen: gen, tree: firstTree, config: .init(maxStalls: 2), property: property
                ) else {
                    continue
                }
                #expect(
                    firstSequence.shortLexPrecedes(secondSequence) == false,
                    "Re-reduction enlarged the sequence (reduction is not monotone) for recipe: \(recipe)"
                )
            }
        }
        #expect(checkedRecipes > 0, "The node budget must not exclude every recipe")
    }
}
