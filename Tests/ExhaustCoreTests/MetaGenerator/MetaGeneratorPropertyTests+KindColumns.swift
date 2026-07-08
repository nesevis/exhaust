import ExhaustCore
import ExhaustTestSupport
import Testing

extension MetaGeneratorPropertyTests {
    // MARK: 17. unique — choice-sequence deduplication

    /// A `unique` (nil key extractor) generator must yield distinct flattened choice sequences within one run. High-cardinality inner so the retry budget is not exhausted.
    @Test("Unique yields distinct choice sequences within a run")
    func uniqueYieldsDistinctSequences() throws {
        let recipe: GenRecipe = .combinator(.unique(.leaf(.int(-1_000_000 ... 1_000_000))))
        let gen = buildGenerator(from: recipe)
        var iter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 30)
        var seen = Set<ChoiceSequence>()
        var count = 0
        while let (_, tree) = try iter.next() {
            count += 1
            #expect(seen.insert(ChoiceSequence.flatten(tree)).inserted, "unique produced a duplicate choice sequence")
        }
        #expect(count > 0, "unique produced no values")
    }

    // MARK: 18. classify — transparency

    /// Classify is a generation-time passthrough: a classified recipe and its unwrapped twin produce identical values from the same seed. The classifier evaluation consumes no randomness, so PRNG consumption is unchanged.
    @Test("Classify is transparent: same values as the unwrapped generator", arguments: metaRecipeTypes)
    func classifyIsTransparent(type: RecipeType) throws {
        var recipeIter = ValueInterpreter(recipeGenerator(producing: type, maxDepth: 1), seed: 42, maxRuns: 20)
        var checkedRecipes = 0
        while let recipe = try recipeIter.next() {
            guard recipe.nodeCount <= metaRecipeNodeBudget else {
                continue
            }
            checkedRecipes += 1
            var plain = ValueInterpreter(buildGenerator(from: recipe), seed: 7, maxRuns: 5)
            var classified = ValueInterpreter(buildGenerator(from: .combinator(.classified(recipe))), seed: 7, maxRuns: 5)
            while let unwrapped = try plain.next(), let wrapped = try classified.next() {
                #expect(anyEquals(unwrapped, wrapped), "classify changed the value for recipe: \(recipe)")
            }
        }
        #expect(checkedRecipes > 0, "The node budget must not exclude every recipe")
    }

    // MARK: 19. scaledArray — length scales with size

    /// Mean generated length is non-decreasing in the size parameter for `.linear` and `.exponential`, and size-independent for `.constant`. Sampled at a small and a large size override.
    @Test("scaledArray mean length scales with size per scaling mode")
    func scaledArrayLengthScalesWithSize() throws {
        for scaling in GenRecipe.RecipeScaling.allCases {
            let recipe: GenRecipe = .combinator(.scaledArray(.leaf(.int(0 ... 5)), lengthRange: 0 ... 20, scaling: scaling))
            let gen = buildGenerator(from: recipe)
            let small = try meanArrayLength(gen, size: 1, samples: 80)
            let large = try meanArrayLength(gen, size: 100, samples: 80)
            switch scaling {
                case .constant:
                    #expect(abs(large - small) <= 1.0, "constant scaling changed mean length with size: small=\(small) large=\(large)")
                case .linear, .exponential:
                    #expect(large > small, "\(scaling.rawValue) scaling did not grow mean length with size: small=\(small) large=\(large)")
            }
        }
    }

    // MARK: 20. weightedOneOf — observed frequencies match declared weights

    /// Observed branch selection frequencies track the declared weights. A `[1, 3]` split over distinguishable `just` branches should land near 25% / 75% across a large sample.
    @Test("weightedOneOf branch frequencies track declared weights")
    func weightedOneOfFrequenciesTrackWeights() throws {
        let recipe: GenRecipe = .combinator(.weightedOneOf([
            .init(weight: 1, recipe: .leaf(.justInt(0))),
            .init(weight: 3, recipe: .leaf(.justInt(1))),
        ]))
        let gen = buildGenerator(from: recipe)
        var iter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 3000)
        var counts = [0, 0]
        while let (value, _) = try iter.next() {
            guard let selected = value as? Int, selected == 0 || selected == 1 else {
                continue
            }
            counts[selected] += 1
        }
        let total = Double(counts[0] + counts[1])
        #expect(total > 0, "weightedOneOf produced no distinguishable values")
        let highWeightFraction = Double(counts[1]) / total
        #expect(abs(highWeightFraction - 0.75) < 0.04, "weightedOneOf frequency off declared 1:3 weights: high-weight fraction=\(highWeightFraction)")
    }
}
