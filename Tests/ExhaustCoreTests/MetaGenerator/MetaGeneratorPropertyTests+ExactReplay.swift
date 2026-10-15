import ExhaustCore
import ExhaustTestSupport
import Testing

extension MetaGeneratorPropertyTests {
    // MARK: 23. Exact Replay of Generated Sequences

    /// The reducer's setup and every exact probe replay a sequence the generator itself produced, and a rejection there silently strips pick alternatives from the graph. The reflection sweeps cannot see this: their trees come from `reflect`, and the materialize-agreement sweep counts a rejection as a skip. Here a rejection is a violation, and the replay must re-emit the sequence it was given.
    @Test("Exact replay accepts the generator's own sequence and re-emits it", arguments: metaRecipeTypes)
    func exactReplayOfGeneratedSequence(type: RecipeType) throws {
        let tally = Tally()
        let badRecipe = try findMinimalCounterexample(recipeGenerator(producing: type, maxDepth: 2), maxIterations: 50) { recipe in
            guard recipe.nodeCount <= metaRecipeNodeBudget else {
                return true
            }
            let gen = buildGenerator(from: recipe)
            return checkExactReplay(gen, tally: tally)
        }
        #expect(badRecipe == nil, "Exact replay rejected or diverged for minimal recipe: \(badRecipe!)")
        #expect(tally.evaluated > 0, "Exact replay sweep for \(type) reached no verdict: \(tally.summary)")
    }

    /// The random sweep draws any one combinator rarely, so a shape that only one combinator builds, such as a bind whose controller ends on a constant arm ahead of a zip bound, can go unsampled. Every fixture runs here regardless.
    @Test("Every combinator fixture exact-replays its own sequences", arguments: reflectableCombinatorFixtures)
    func exactReplayOfCombinatorFixture(fixture: CombinatorFixture) {
        let tally = Tally()
        #expect(checkExactReplay(buildGenerator(from: fixture.recipe), maxRuns: 20, tally: tally), "Exact replay rejected or diverged for \(fixture.name)")
        #expect(tally.evaluated > 0, "Exact replay of \(fixture.name) reached no verdict: \(tally.summary)")
    }
}

// MARK: - Helpers

/// Replays every generated tree's flattening in exact mode, with and without alternative branches in both the generated tree and the replay, and returns false at the first rejection or divergence.
///
/// Sampling produces stripped trees and screening produces full ones, and the reducer rematerializes either with alternatives, so all four combinations are reachable.
private func checkExactReplay(_ gen: AnyGenerator, maxRuns: UInt64 = 10, tally: Tally) -> Bool {
    for generatedWithPicks in [false, true] {
        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: generatedWithPicks, seed: 42, maxRuns: maxRuns)
        while true {
            let element: (value: Any, tree: ChoiceTree)?
            do {
                element = try iterator.next()
            } catch {
                tally.thrown += 1
                break
            }
            guard let (value, tree) = element else {
                break
            }
            let sequence = ChoiceSequence.flatten(tree)
            for replayWithPicks in [false, true] {
                let result = Materializer.materialize(gen, context: .init(
                    prefix: sequence,
                    mode: .exact,
                    fallbackTree: tree,
                    materializePicks: replayWithPicks
                ))
                tally.evaluated += 1
                guard case let .success(replayed, replayedTree, _) = result,
                      anyEquals(value, replayed),
                      ChoiceSequence.flatten(replayedTree) == sequence
                else {
                    return false
                }
            }
        }
    }
    return true
}
