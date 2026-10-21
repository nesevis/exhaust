import ExhaustCore
import ExhaustTestSupport
import Testing

extension MetaGeneratorPropertyTests {
    /// These laws share the same recipes, sampled failures, and first reduction. Keep the reducer outside a dogfooded property to avoid circular validation.
    @Test("Reduction preserves failure, replays its result, and never enlarges eligible histories", arguments: metaRecipeTypes)
    func reductionLaws(type: RecipeType) throws {
        var recipes = ValueInterpreter(recipeGenerator(producing: type, maxDepth: 1), seed: 42, maxRuns: 20)
        let property = failingProperty(for: type)
        var reductions = 0
        var complexityChecks = 0
        var repeatedChecks = 0
        while let recipe = try recipes.next() {
            guard recipe.nodeCount <= metaRecipeNodeBudget else {
                continue
            }
            let generator = buildGenerator(from: recipe)
            var values = ValueAndChoiceTreeInterpreter(generator, seed: 7, maxRuns: 20)
            while let (value, tree) = try values.next() {
                guard property(value) == false,
                      case let .reduced(sequence, reducedTree, reducedValue) = Interpreters.choiceGraphReduce(
                          gen: generator, tree: tree, config: .init(maxStalls: 2), property: property
                      )
                else {
                    continue
                }
                reductions += 1
                #expect(property(reducedValue) == false, "Reduction lost the failure for \(recipe)")
                if case let .success(materialized, _, _) = Materializer.materialize(
                    generator, context: .init(prefix: sequence, mode: .exact, fallbackTree: reducedTree)
                ) {
                    #expect(anyEquals(materialized, reducedValue), "Reduced history disagrees with the reported value for \(recipe)")
                } else {
                    Issue.record("Reduced history failed exact replay for \(recipe)")
                }

                // Constant-arm re-encoding intentionally expands the starting representation.
                if ConstantArmReencoder.reencodesStart(of: tree, gen: generator) == false {
                    let original = ChoiceSequence.flatten(tree)
                    #expect(sequence.shortLexPrecedes(original) || sequence == original, "Reduction enlarged \(recipe)")
                    complexityChecks += 1
                }
                guard ConstantArmReencoder.reencodesStart(of: reducedTree, gen: generator) == false else {
                    continue
                }
                let repeated = Interpreters.choiceGraphReduce(
                    gen: generator, tree: reducedTree, config: .init(maxStalls: 2), property: property
                )
                // A bounded reducer may stop at a fixed point or improve again; both outcomes carry a counterexample.
                let (repeatedSequence, repeatedValue) = try #require(repeated.counterexample)
                #expect(property(repeatedValue) == false)
                #expect(sequence.shortLexPrecedes(repeatedSequence) == false, "Re-reduction enlarged \(recipe)")
                repeatedChecks += 1
            }
        }
        #expect(reductions > 0, "No failure reduced for \(type)")
        #expect(complexityChecks > 0, "No reduction qualified for the complexity law for \(type)")
        #expect(repeatedChecks > 0, "No reduction qualified for the repeated-reduction law for \(type)")
    }
}
