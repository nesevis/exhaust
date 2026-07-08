import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Meta-Generator Property Tests", .tags(.dogfood))
struct MetaGeneratorPropertyTests {
    private let simpleIntRecipeGen = recipeGenerator(producing: .int, maxDepth: 1)

    // MARK: 1. Reflection Round-Trip

    @Test("Generated generators round-trip through reflect and replay", arguments: metaRecipeTypes)
    func reflectionRoundTrip(type: RecipeType) throws {
        let tally = Tally()
        let badRecipe = try findMinimalCounterexample(recipeGenerator(producing: type, maxDepth: 2), maxIterations: 50) { recipe in
            guard recipe.nodeCount <= metaRecipeNodeBudget else { return true }
            let gen = buildGenerator(from: recipe)
            return checkAllValues(gen, maxRuns: 10, tally: tally) { value in
                guard let tree = try Interpreters.reflect(gen, with: value) else { return nil }
                guard let replayed = try Interpreters.replay(gen, using: tree) else { return nil }
                return anyEquals(value, replayed)
            }
        }
        #expect(badRecipe == nil, "Round-trip failed for minimal recipe: \(badRecipe!)")
        #expect(tally.evaluated > 0, "Round-trip sweep for \(type) reached no verdict: \(tally.summary)")
    }

    // MARK: 2. Replay Determinism

    @Test("Replaying the same ChoiceTree produces identical values", arguments: metaRecipeTypes)
    func replayDeterminism(type: RecipeType) throws {
        let tally = Tally()
        let badRecipe = try findMinimalCounterexample(recipeGenerator(producing: type, maxDepth: 2), maxIterations: 50) { recipe in
            guard recipe.nodeCount <= metaRecipeNodeBudget else { return true }
            let gen = buildGenerator(from: recipe)
            return checkAllTrees(gen, maxRuns: 10, tally: tally) { tree in
                guard let r1 = try Interpreters.replay(gen, using: tree),
                      let r2 = try Interpreters.replay(gen, using: tree) else { return nil }
                return anyEquals(r1, r2)
            }
        }
        #expect(badRecipe == nil, "Replay not deterministic for minimal recipe: \(badRecipe!)")
        #expect(tally.evaluated > 0, "Replay-determinism sweep for \(type) reached no verdict: \(tally.summary)")
    }

    // MARK: 3. Materialize Agreement

    @Test("Materialize with flattened tree agrees with replay", arguments: metaRecipeTypes)
    func materializeAgreement(type: RecipeType) throws {
        let tally = Tally()
        let badRecipe = try findMinimalCounterexample(recipeGenerator(producing: type, maxDepth: 2), maxIterations: 50) { recipe in
            guard recipe.nodeCount <= metaRecipeNodeBudget else { return true }
            let gen = buildGenerator(from: recipe)
            return checkAllValues(gen, maxRuns: 10, tally: tally) { value in
                guard let reflectedTree = try Interpreters.reflect(gen, with: value) else { return nil }
                guard let replayed = try Interpreters.replay(gen, using: reflectedTree) else { return nil }
                let sequence = ChoiceSequence.flatten(reflectedTree)
                guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: reflectedTree) else { return nil }
                return anyEquals(materialized, replayed)
            }
        }
        #expect(badRecipe == nil, "Materialize disagrees with replay for minimal recipe: \(badRecipe!)")
        #expect(tally.evaluated > 0, "Materialize sweep for \(type) reached no verdict: \(tally.summary)")
    }

    // MARK: 3b. Interpreter Parity

    @Test("VI and VACTI consume the PRNG identically for random recipes", arguments: metaRecipeTypes)
    func interpreterParity(type: RecipeType) throws {
        var recipeIter = ValueInterpreter(recipeGenerator(producing: type, maxDepth: 2), seed: 42, maxRuns: 30)
        var checkedRecipes = 0
        while let recipe = try recipeIter.next() {
            guard recipe.nodeCount <= metaRecipeNodeBudget else { continue }
            checkedRecipes += 1
            let gen = buildGenerator(from: recipe)
            var vi = ValueInterpreter(gen, seed: 7, maxRuns: 5)
            var vacti = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 7, maxRuns: 5)
            for iteration in 0 ..< 5 {
                let viValue = try vi.next()
                let vactiPair = try vacti.next()
                switch (viValue, vactiPair) {
                    case (nil, nil):
                        continue
                    case let (.some(a), .some(pair)):
                        #expect(
                            anyEquals(a, pair.0),
                            "Iteration \(iteration): VI=\(a), VACTI=\(pair.0) for recipe: \(recipe)"
                        )
                    default:
                        Issue.record("Iteration \(iteration): one interpreter exhausted before the other for recipe: \(recipe)")
                }
            }
        }
        #expect(checkedRecipes > 0, "The node budget must not exclude every recipe")
    }

    // MARK: 3c. Reflect Stabilization

    @Test("Reflect stabilizes after one round for random recipes", arguments: metaRecipeTypes)
    func reflectStabilizes(type: RecipeType) throws {
        let tally = Tally()
        let badRecipe = try findMinimalCounterexample(recipeGenerator(producing: type, maxDepth: 2), maxIterations: 50) { recipe in
            guard recipe.nodeCount <= metaRecipeNodeBudget else { return true }
            let gen = buildGenerator(from: recipe)
            return checkAllValues(gen, maxRuns: 10, tally: tally) { value in
                guard let tree1 = try Interpreters.reflect(gen, with: value) else { return nil }
                guard let replayed = try Interpreters.replay(gen, using: tree1) else { return nil }
                guard let tree2 = try Interpreters.reflect(gen, with: replayed) else { return nil }
                guard let replayed2 = try Interpreters.replay(gen, using: tree2) else { return nil }
                return anyEquals(replayed, replayed2)
            }
        }
        #expect(badRecipe == nil, "Reflect did not stabilize for minimal recipe: \(badRecipe!)")
        #expect(tally.evaluated > 0, "Reflect-stabilization sweep for \(type) reached no verdict: \(tally.summary)")
    }

    // MARK: 3e. Fast-Path Parity

    /// `nextValueOnly()` (the tree-free fast path, backed by ValueInterpreter) and `reproduceWithTree()` (the tree-building path) must produce the same value for the same run. This is the contract the sampling pipeline relies on; `reproduceFailureTree()` asserts it at runtime and falls back to `.just` when it breaks. Sweeping it over the recipe space checks it for every generator shape, not just the ones the pipeline happened to hit.
    ///
    /// Recipes containing `unique` are exempt. The fast path's ValueInterpreter pass records the drawn choice sequence in the unique dedup set, so `reproduceWithTree()`'s re-run sees its own sequence as a duplicate and retries a different value. Production sidesteps this the same way: `nextValueOnly()` falls back to `next()` once `uniqueSeenSequences` is non-empty, and `reproduceFailureTree()` returns `.just` on the resulting break rather than trusting the reproduction.
    @Test("Fast-path nextValueOnly agrees with reproduceWithTree for random recipes", arguments: metaRecipeTypes)
    func fastPathParity(type: RecipeType) throws {
        var recipeIter = ValueInterpreter(recipeGenerator(producing: type, maxDepth: 2), seed: 42, maxRuns: 30)
        var checkedRecipes = 0
        while let recipe = try recipeIter.next() {
            guard recipe.nodeCount <= metaRecipeNodeBudget, containsUnique(recipe) == false else { continue }
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

    // MARK: 4. Functor Identity

    @Test("Mapping with identity produces same values")
    func functorIdentity() throws {
        let badRecipe = try findMinimalCounterexample(simpleIntRecipeGen, maxIterations: 50) { recipe in
            let gen = buildGenerator(from: recipe)
            let mappedGen: AnyGenerator = Gen.contramap(
                { (newOutput: Any) throws -> Any in newOutput },
                gen.map(\.self)
            )
            return checkPairedValues(gen, mappedGen, maxRuns: 10) { v1, v2 in
                anyEquals(v1, v2)
            }
        }
        #expect(badRecipe == nil, "Functor identity failed for minimal recipe: \(badRecipe!)")
    }

    // MARK: 5. Functor Composition

    @Test("map(f).map(g) produces same values as map(g . f)")
    func functorComposition() throws {
        let intLeafGen = recipeGenerator(producing: .int, maxDepth: 0)
        let badRecipe = try findMinimalCounterexample(intLeafGen, maxIterations: 50) { recipe in
            let gen = buildGenerator(from: recipe)
            let f: (Any) -> Any = { ($0 as! Int) * 2 }
            let g: (Any) -> Any = { ($0 as! Int) + 1 }
            let composed1 = gen.map(f).map(g)
            let composed2 = gen.map { g(f($0)) }
            return checkPairedValues(composed1, composed2, maxRuns: 10) { v1, v2 in
                anyEquals(v1, v2)
            }
        }
        #expect(badRecipe == nil, "Functor composition failed for minimal recipe: \(badRecipe!)")
    }

    // MARK: 6. Monad Left Identity

    @Test("just(x).bind(f) produces same values as f(x)")
    func monadLeftIdentity() throws {
        let badValue = try findMinimalCounterexample(
            Gen.choose(in: -100 ... 100 as ClosedRange<Int>),
            maxIterations: 50, seed: 7
        ) { x in
            let f: (Int) -> Generator<Int> = { val in Gen.choose(in: val ... (val + 10)) }
            let lhs: Generator<Int> = Gen.just(x).bind { f($0) }
            let rhs: Generator<Int> = f(x)
            var lhsIter = ValueInterpreter(lhs, seed: 99, maxRuns: 5)
            var rhsIter = ValueInterpreter(rhs, seed: 99, maxRuns: 5)
            do {
                while let v1 = try lhsIter.next(), let v2 = try rhsIter.next() {
                    if v1 != v2 { return false }
                }
            } catch { return true }
            return true
        }
        #expect(badValue == nil, "Monad left identity failed for x=\(badValue!)")
    }

    // MARK: 7. Monad Right Identity

    @Test("gen.bind(just) produces same values as gen")
    func monadRightIdentity() throws {
        let intLeafGen = recipeGenerator(producing: .int, maxDepth: 0)
        let badRecipe = try findMinimalCounterexample(intLeafGen, maxIterations: 50) { recipe in
            let gen = buildGenerator(from: recipe)
            let boundGen = gen.bind { .pure($0) }
            return checkPairedValues(gen, boundGen, maxRuns: 10) { v1, v2 in
                anyEquals(v1, v2)
            }
        }
        #expect(badRecipe == nil, "Monad right identity failed for minimal recipe: \(badRecipe!)")
    }

    // MARK: 8. Reduction Preserves Failure (manual — circular if dogfooded)

    @Test("Reduced values still fail the original property", arguments: metaRecipeTypes)
    func reductionPreservesFailure(type: RecipeType) throws {
        let recipeGen = recipeGenerator(producing: type, maxDepth: 1)
        var recipeIter = ValueInterpreter(recipeGen, seed: 42, maxRuns: 20)
        let property = failingProperty(for: type)
        while let recipe = try recipeIter.next() {
            guard recipe.nodeCount <= metaRecipeNodeBudget else {
                continue
            }
            let gen = buildGenerator(from: recipe)

            var valueIter = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 20)
            while let (value, tree) = try valueIter.next() {
                guard property(value) == false else { continue }
                guard case let .reduced(_, _, shrunk) = try? Interpreters.choiceGraphReduce(
                    gen: gen, tree: tree, config: .init(maxStalls: 2), property: property
                ) else { continue }
                #expect(
                    property(shrunk) == false,
                    "Shrunk value passes property but shouldn't, recipe: \(recipe)"
                )
            }
        }
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
                guard property(value) == false else { continue }
                let originalSequence = ChoiceSequence.flatten(tree)
                guard case let .reduced(shrunkSequence, _, _) = try? Interpreters.choiceGraphReduce(
                    gen: gen, tree: tree, config: .init(maxStalls: 2), property: property
                ) else { continue }
                #expect(
                    shrunkSequence.shortLexPrecedes(originalSequence) || shrunkSequence == originalSequence,
                    "Shrunk sequence is not simpler than the original, recipe: \(recipe)"
                )
            }
        }
        #expect(checkedRecipes > 0, "The node budget must not exclude every recipe")
    }

    // MARK: 9. Filter Correctness

    @Test("Filtered generators only produce values satisfying the predicate")
    func filterCorrectness() throws {
        let intLeafGen = recipeGenerator(producing: .int, maxDepth: 0)
        var recipeIter = ValueInterpreter(intLeafGen, seed: 42, maxRuns: 20)
        while let recipe = try recipeIter.next() {
            for predicate in KnownPredicate.applicable(to: recipe.outputType) {
                let innerGen: AnyGenerator
                if predicate == .isPositive {
                    innerGen = Gen.choose(in: -10 ... 100 as ClosedRange<Int>).erase()
                } else if predicate == .isNonEmpty {
                    continue
                } else {
                    innerGen = buildGenerator(from: recipe)
                }

                let filteredGen: AnyGenerator = .impure(
                    operation: .filter(
                        gen: innerGen.erase(),
                        fingerprint: Gen.sourceFingerprint(fileID: #fileID, line: #line, column: #column),
                        filterType: .auto,
                        predicate: { predicate.evaluate($0) },
                        sourceLocation: FilterSourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
                    ),
                    continuation: { .pure($0) }
                )

                var valueIter = ValueInterpreter(filteredGen, seed: 42, maxRuns: 15)
                while let value = try valueIter.next() {
                    #expect(
                        predicate.evaluate(value),
                        "Filter \(predicate) violated for recipe: \(recipe)"
                    )
                }
            }
        }
    }

    // MARK: 10. Size Bounds

    @Test("choose(in: range) values are always within range")
    func sizeBounds() throws {
        let intRecipeGen = recipeGenerator(producing: .int, maxDepth: 2)
        let badRecipe = try findMinimalCounterexample(intRecipeGen, maxIterations: 50) { recipe in
            guard case let .leaf(.int(range)) = recipe else { return true }
            let gen = Gen.choose(in: range)
            do {
                var valueIter = ValueInterpreter(gen, seed: 42, maxRuns: 20)
                while let value = try valueIter.next() {
                    if range.contains(value) == false { return false }
                }
            } catch { return true }
            return true
        }
        #expect(badRecipe == nil, "Value outside range for minimal recipe: \(badRecipe!)")
    }

    // MARK: 11. Just Values

    @Test("Just values always produce the same constant")
    func justValuesAreConstant() throws {
        let justRecipes: [GenRecipe] = [
            .leaf(.justInt(42)),
            .leaf(.justInt(-7)),
            .leaf(.justInt(0)),
            .leaf(.justBool(true)),
            .leaf(.justBool(false)),
            .leaf(.justIntArray([1, 2, 3])),
            .leaf(.justIntArray([])),
        ]

        for recipe in justRecipes {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 5)
            var first: Any?
            while let (value, _) = try valueIter.next() {
                if let first {
                    #expect(
                        anyEquals(first, value),
                        "Just generator produced different values for recipe: \(recipe)"
                    )
                } else {
                    first = value
                }
            }
        }
    }

    @Test("Just values round-trip through reflect and replay")
    func justValuesReflectionRoundTrip() throws {
        let justRecipes: [GenRecipe] = [
            .leaf(.justInt(42)),
            .leaf(.justBool(true)),
            .leaf(.justIntArray([10, 20])),
            .leaf(.justIntArray([])),
        ]

        for recipe in justRecipes {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 3)
            while let (value, _) = try valueIter.next() {
                let tree = try #require(try Interpreters.reflect(gen, with: value), "Just must reflect for recipe: \(recipe)")
                let replayed = try #require(try Interpreters.replay(gen, using: tree), "Just must replay for recipe: \(recipe)")
                #expect(
                    anyEquals(value, replayed),
                    "Just round-trip failed for recipe: \(recipe)"
                )
            }
        }
    }

    // MARK: 12. Zipped Generators

    @Test("Zipped generators round-trip through reflect and replay")
    func zippedReflectionRoundTrip() throws {
        let zippedRecipes: [GenRecipe] = [
            .combinator(.zipped(.leaf(.int(-10 ... 10)), .leaf(.int(0 ... 100)))),
            .combinator(.zipped(.leaf(.justInt(5)), .leaf(.int(-5 ... 5)))),
            .combinator(.zipped(.leaf(.bool), .leaf(.bool))),
        ]

        for recipe in zippedRecipes {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 10)
            while let (value, _) = try valueIter.next() {
                let tree = try #require(try Interpreters.reflect(gen, with: value), "Zip must reflect for recipe: \(recipe)")
                let replayed = try #require(try Interpreters.replay(gen, using: tree), "Zip must replay for recipe: \(recipe)")
                #expect(
                    anyEquals(value, replayed),
                    "Zip round-trip failed for recipe: \(recipe)"
                )
            }
        }
    }

    @Test("Zipped generators replay deterministically")
    func zippedReplayDeterminism() throws {
        let zippedRecipes: [GenRecipe] = [
            .combinator(.zipped(.leaf(.int(-10 ... 10)), .leaf(.int(0 ... 100)))),
            .combinator(.zipped(.leaf(.justInt(5)), .leaf(.justInt(10)))),
            .combinator(.zipped(.leaf(.bool), .leaf(.int(0 ... 50)))),
        ]

        for recipe in zippedRecipes {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 10)
            while let (_, tree) = try valueIter.next() {
                let r1 = try #require(try Interpreters.replay(gen, using: tree), "Zip must replay for recipe: \(recipe)")
                let r2 = try #require(try Interpreters.replay(gen, using: tree), "Zip must replay for recipe: \(recipe)")
                #expect(
                    anyEquals(r1, r2),
                    "Zip replay not deterministic for recipe: \(recipe)"
                )
            }
        }
    }

    @Test("Zipped generators materialize consistently")
    func zippedMaterializeAgreement() throws {
        let zippedRecipes: [GenRecipe] = [
            .combinator(.zipped(.leaf(.int(-10 ... 10)), .leaf(.int(0 ... 100)))),
            .combinator(.zipped(.leaf(.justInt(5)), .leaf(.int(-5 ... 5)))),
        ]

        for recipe in zippedRecipes {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 10)
            while let (value, _) = try valueIter.next() {
                let reflectedTree = try #require(try Interpreters.reflect(gen, with: value), "Zip must reflect for recipe: \(recipe)")
                let replayed = try #require(try Interpreters.replay(gen, using: reflectedTree), "Zip must replay for recipe: \(recipe)")
                let sequence = ChoiceSequence.flatten(reflectedTree)
                guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: reflectedTree) else {
                    Issue.record("Zip must materialize for recipe: \(recipe)")
                    continue
                }
                #expect(
                    anyEquals(materialized, replayed),
                    "Zip materialize disagrees with replay for recipe: \(recipe)"
                )
            }
        }
    }

    // MARK: 13. Optional Generators

    @Test("Optional generators produce both nil and non-nil values")
    func optionalProducesBothBranches() throws {
        let optionalRecipes: [GenRecipe] = [
            .combinator(.optional(.leaf(.int(-10 ... 10)))),
            .combinator(.optional(.leaf(.bool))),
            .combinator(.optional(.leaf(.justInt(7)))),
        ]

        for recipe in optionalRecipes {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 50)
            var sawNil = false
            var sawSome = false
            while let (value, _) = try valueIter.next() {
                let mirror = Mirror(reflecting: value)
                if mirror.displayStyle == .optional, mirror.children.first == nil {
                    sawNil = true
                } else {
                    sawSome = true
                }
                if sawNil, sawSome { break }
            }
            #expect(sawNil, "Optional recipe \(recipe) never produced nil")
            #expect(sawSome, "Optional recipe \(recipe) never produced a value")
        }
    }

    @Test("Optional generators replay deterministically")
    func optionalReplayDeterminism() throws {
        let optionalRecipes: [GenRecipe] = [
            .combinator(.optional(.leaf(.int(-10 ... 10)))),
            .combinator(.optional(.leaf(.bool))),
        ]

        for recipe in optionalRecipes {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 15)
            while let (_, tree) = try valueIter.next() {
                let r1 = try #require(try Interpreters.replay(gen, using: tree), "Optional must replay for recipe: \(recipe)")
                let r2 = try #require(try Interpreters.replay(gen, using: tree), "Optional must replay for recipe: \(recipe)")
                #expect(
                    anyEquals(r1, r2),
                    "Optional replay not deterministic for recipe: \(recipe)"
                )
            }
        }
    }

    @Test("Optional generators materialize consistently")
    func optionalMaterializeAgreement() throws {
        let optionalRecipes: [GenRecipe] = [
            .combinator(.optional(.leaf(.int(0 ... 100)))),
            .combinator(.optional(.leaf(.justInt(5)))),
        ]

        for recipe in optionalRecipes {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 15)
            while let (value, _) = try valueIter.next() {
                let reflectedTree = try #require(try Interpreters.reflect(gen, with: value), "Optional must reflect for recipe: \(recipe)")
                let replayed = try #require(try Interpreters.replay(gen, using: reflectedTree), "Optional must replay for recipe: \(recipe)")
                let sequence = ChoiceSequence.flatten(reflectedTree)
                guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: reflectedTree) else {
                    Issue.record("Optional must materialize for recipe: \(recipe)")
                    continue
                }
                #expect(
                    anyEquals(materialized, replayed),
                    "Optional materialize disagrees with replay for recipe: \(recipe)"
                )
            }
        }
    }

    @Test("Nested optional generators round-trip through reflect and replay, including mid-chain nils")
    func nestedOptionalReflectionRoundTrip() throws {
        let nestedRecipes: [GenRecipe] = [
            .combinator(.optional(.combinator(.optional(.leaf(.int(-10 ... 10)))))),
            .combinator(.optional(.combinator(.optional(.combinator(.optional(.leaf(.justInt(7)))))))),
        ]

        for recipe in nestedRecipes {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 60)
            var sawNilBearing = false
            while let (value, _) = try valueIter.next() {
                if containsNil(value) {
                    sawNilBearing = true
                }
                let tree = try Interpreters.reflect(gen, with: value)
                let replayed = try tree.flatMap { try Interpreters.replay(gen, using: $0) }
                #expect(replayed != nil, "Reflect or replay produced nil for \(value) with recipe: \(recipe)")
                if let replayed {
                    #expect(
                        anyEquals(value, replayed),
                        "Nested optional round-trip failed for \(value) with recipe: \(recipe)"
                    )
                }
            }
            #expect(sawNilBearing, "The sweep never exercised a nil-bearing value for recipe: \(recipe)")
        }
    }

    @Test("anyEquals correctly compares optional values")
    func optionalEquality() {
        #expect(anyEquals(Any?.none as Any, Any?.none as Any))
        #expect(anyEquals(Any?.some(42) as Any, Any?.some(42) as Any))
        #expect(anyEquals(Any?.some(42) as Any, 42 as Any))
        #expect(anyEquals(Any?.none as Any, Any?.some(42) as Any) == false)
        #expect(anyEquals(Any?.some(1) as Any, Any?.some(2) as Any) == false)
    }

    // MARK: 14. Random Recipes with Just/Zip

    /// Depth-2 recipes were blocked by three constraints, all resolved 2026-07-07: the debug stack budget (interpreter case handlers outlined, budget recalibrated), the aliased nested-filter tuning cycle (filter expansion-path guard in GenerationContext), and nested-optional reflection (liftToOptional-style backward in the recipe fixture plus branch-probe error containment in reflectPickOperation).
    @Test("Random recipes with just and zip round-trip through reflect and replay")
    func randomJustZipRecipesRoundTrip() throws {
        let recipeGen = recipeGenerator(producing: .int, maxDepth: 2)
        var recipeIter = ValueInterpreter(recipeGen, seed: 42, maxRuns: 40)
        while let recipe = try recipeIter.next() {
            guard recipe.nodeCount <= metaRecipeNodeBudget else {
                continue
            }
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 5)
            while let (value, _) = try valueIter.next() {
                guard let tree = try? Interpreters.reflect(gen, with: value) else { continue }
                guard let replayed = try? Interpreters.replay(gen, using: tree) else { continue }
                #expect(
                    anyEquals(value, replayed),
                    "Round-trip failed for recipe: \(recipe)"
                )
            }
        }
    }

    // MARK: 15. Per-Combinator Reflection Coverage

    /// Asserts every reflectable combinator actually reflects and round-trips at least one of its own generated values.
    ///
    /// The round-trip sweeps skip any value whose generator fails to reflect (`catch { return true }` in `checkAllValues`, `else { continue }` in the fixture tests), so a combinator that silently stopped reflecting would leave those tests green. Zip did exactly this for months: a projecting `.map` made its output unreflectable and every zip assertion was skipped unseen. Each fixture here uses `#require`, so any regression that breaks a reflectable combinator fails loudly rather than passing vacuously. `boundRange` and `unfolded` are excluded because their bind/unfold construction is forward-only — nil reflection is expected for them, not a defect.
    @Test("Every reflectable combinator reflects and round-trips", arguments: reflectableCombinatorFixtures)
    func everyReflectableCombinatorRoundTrips(fixture: CombinatorFixture) throws {
        let gen = buildGenerator(from: fixture.recipe)
        var valueIter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 12)
        var roundTripped = 0
        while let (value, _) = try valueIter.next() {
            let tree = try #require(try Interpreters.reflect(gen, with: value), "\(fixture.name) must reflect its own value")
            let replayed = try #require(try Interpreters.replay(gen, using: tree), "\(fixture.name) must replay")
            #expect(anyEquals(value, replayed), "\(fixture.name) round-trip mismatch")
            roundTripped += 1
        }
        #expect(roundTripped > 0, "\(fixture.name) produced no values to check")
    }

    // MARK: 16. Forward-Only Exemption (pinned)

    /// Pins the combinators the coverage sweep deliberately omits, so their exemption is an assertion rather than silence.
    ///
    /// `unfolded` builds a `bindReified` chain with no backward, so reflection throws for every value. `boundRange` uses the invisible `FreerMonad.bind`, whose dependent `choose` reflects only occasionally. Both are excluded from ``reflectableCombinatorFixtures`` because a nil or thrown reflection is expected, not a defect. Asserting that here means that if backward support is ever added — making these reflect — this test fails and prompts promoting the kind into the reflectable set and the round-trip sweeps.
    @Test("Forward-only combinators stay unreflectable")
    func forwardOnlyCombinatorsStayUnreflectable() throws {
        let unfolded: GenRecipe = .combinator(.unfolded(depthRange: 0 ... 3))
        let unfoldedReflected = try reflectableValueCount(unfolded, seed: 42, maxRuns: 12)
        #expect(unfoldedReflected == 0, "unfolded reflected \(unfoldedReflected)/12 values — it is now reflectable, so promote it into reflectableCombinatorFixtures and the round-trip sweeps")

        let boundRange: GenRecipe = .combinator(.boundRange(.leaf(.int(0 ... 10))))
        let boundRangeReflected = try reflectableValueCount(boundRange, seed: 42, maxRuns: 12)
        #expect(boundRangeReflected < 12, "boundRange reflected all 12 values — it is now fully reflectable, so promote it into reflectableCombinatorFixtures and the round-trip sweeps")
    }
}

// MARK: - Helpers

/// Accumulates how often a swept invariant reached a real verdict versus skipped one.
///
/// A cell in the matrix can pass three ways: the check ran and held (`evaluated`), the operation could not reflect so the check returned nil (`vacuous`), or reflection threw and the helper swallowed it (`thrown`). The test report shows only pass or fail, so without this a whole (kind, invariant) cell can be green because it never actually ran. Each swept invariant asserts `evaluated > 0` against its tally so wholesale vacuity fails loudly.
final class Tally {
    var evaluated = 0
    var vacuous = 0
    var thrown = 0

    var summary: String {
        "evaluated=\(evaluated), vacuous=\(vacuous), thrown=\(thrown)"
    }
}

/// Checks a property against all generated values, recording verdicts into `tally`. Returns true if the property held for every value that produced a verdict.
///
/// The `check` returns `nil` to signal a vacuous skip (for example, a forward-only generator that cannot reflect), `true` for a held verdict, and `false` for a violation. A throw from generation or from `check` is counted as `thrown`, not propagated, so a recoverable reflection failure is recorded rather than silently treated as a pass.
private func checkAllValues(
    _ gen: AnyGenerator,
    maxRuns: UInt64 = 10,
    tally: Tally,
    check: (Any) throws -> Bool?
) -> Bool {
    var iter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: maxRuns)
    while true {
        let element: (value: Any, tree: ChoiceTree)?
        do {
            element = try iter.next()
        } catch {
            tally.thrown += 1
            return true
        }
        guard let (value, _) = element else { return true }
        do {
            switch try check(value) {
                case .none:
                    tally.vacuous += 1
                case .some(true):
                    tally.evaluated += 1
                case .some(false):
                    tally.evaluated += 1
                    return false
            }
        } catch {
            tally.thrown += 1
        }
    }
}

/// Checks a property against all generated choice trees, recording verdicts into `tally`. Returns true if the property held for every tree that produced a verdict. See ``checkAllValues`` for the `nil`/`true`/`false` contract.
private func checkAllTrees(
    _ gen: AnyGenerator,
    maxRuns: UInt64 = 10,
    tally: Tally,
    check: (ChoiceTree) throws -> Bool?
) -> Bool {
    var iter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: maxRuns)
    while true {
        let element: (value: Any, tree: ChoiceTree)?
        do {
            element = try iter.next()
        } catch {
            tally.thrown += 1
            return true
        }
        guard let (_, tree) = element else { return true }
        do {
            switch try check(tree) {
                case .none:
                    tally.vacuous += 1
                case .some(true):
                    tally.evaluated += 1
                case .some(false):
                    tally.evaluated += 1
                    return false
            }
        } catch {
            tally.thrown += 1
        }
    }
}

/// Checks that two generators produce pairwise-equal values from the same seed.
private func checkPairedValues(
    _ gen1: AnyGenerator,
    _ gen2: AnyGenerator,
    seed: UInt64 = 42,
    maxRuns: UInt64 = 10,
    check: (Any, Any) -> Bool
) -> Bool {
    do {
        var iter1 = ValueInterpreter(gen1, seed: seed, maxRuns: maxRuns)
        var iter2 = ValueInterpreter(gen2, seed: seed, maxRuns: maxRuns)
        while let v1 = try iter1.next(), let v2 = try iter2.next() {
            if check(v1, v2) == false { return false }
        }
    } catch {
        return true
    }
    return true
}

/// A property with a satisfiable failure condition for each recipe output type, so reduction has counterexamples to preserve. Values of unexpected types pass vacuously, matching the original int-only formulation.
private func failingProperty(for type: RecipeType) -> (Any) -> Bool {
    switch type {
        case .int:
            { value in (value as? Int).map { $0 < 10 } ?? true }
        case .bool:
            { value in (value as? Bool).map { $0 == false } ?? true }
        case .arrayOf:
            { value in (value as? [Any]).map { $0.count < 2 } ?? true }
    }
}

/// Returns whether the recipe contains a combinator of the given kind at any depth, matched by `predicate`.
private func recipeContains(_ recipe: GenRecipe, where predicate: (GenRecipe.CombinatorKind) -> Bool) -> Bool {
    guard case let .combinator(kind) = recipe else { return false }
    if predicate(kind) {
        return true
    }
    switch kind {
        case let .mapped(inner, _),
             let .array(inner, _),
             let .filtered(inner, _),
             let .resized(inner, _),
             let .optional(inner),
             let .boundRange(inner),
             let .scaledArray(inner, _, _),
             let .classified(inner),
             let .metamorphed(inner, _),
             let .unique(inner):
            return recipeContains(inner, where: predicate)
        case let .boundArray(element, _):
            return recipeContains(element, where: predicate)
        case let .recursive(base, _):
            return recipeContains(base, where: predicate)
        case let .oneOf(recipes):
            return recipes.contains { recipeContains($0, where: predicate) }
        case let .weightedOneOf(branches):
            return branches.contains { recipeContains($0.recipe, where: predicate) }
        case let .zipped(first, second):
            return recipeContains(first, where: predicate) || recipeContains(second, where: predicate)
        case .unfolded:
            return false
    }
}

/// Returns whether the recipe contains a `unique` combinator at any depth.
private func containsUnique(_ recipe: GenRecipe) -> Bool {
    recipeContains(recipe) { kind in
        if case .unique = kind {
            return true
        }
        return false
    }
}

/// Counts how many of a recipe's generated values reflect to a non-nil tree. A throw or a nil reflection both count as "did not reflect", since `try?` collapses them.
private func reflectableValueCount(_ recipe: GenRecipe, seed: UInt64, maxRuns: UInt64) throws -> Int {
    let gen = buildGenerator(from: recipe)
    var iter = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: maxRuns)
    var reflected = 0
    while let (value, _) = try iter.next() {
        if (try? Interpreters.reflect(gen, with: value)) != nil {
            reflected += 1
        }
    }
    return reflected
}

/// Returns whether the value is nil at any level of optional nesting.
private func containsNil(_ value: Any) -> Bool {
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle == .optional else {
        return false
    }
    guard let child = mirror.children.first else {
        return true
    }
    return containsNil(child.value)
}

// MARK: - Matrix Configuration

/// Output types the universal invariants sweep over. Every operation the recipe language can produce for these types gets each invariant automatically.
let metaRecipeTypes: [RecipeType] = [.int, .bool, .arrayOf(.int)]

/// A named recipe exercising a single combinator, for the per-combinator reflection-coverage sweep.
struct CombinatorFixture: Sendable, CustomStringConvertible {
    let name: String
    let recipe: GenRecipe

    var description: String {
        name
    }
}

/// One fixture per combinator whose output is reflectable, so the coverage sweep can assert each reflects rather than skipping it. `boundRange` and `unfolded` are omitted deliberately: both build on a backward-less `.bind`/unfold, so their outputs are not reflectable by construction and a nil reflection is expected rather than a regression.
let reflectableCombinatorFixtures: [CombinatorFixture] = [
    .init(name: "mapped", recipe: .combinator(.mapped(.leaf(.int(0 ... 10)), .increment))),
    .init(name: "array", recipe: .combinator(.array(.leaf(.int(0 ... 5)), lengthRange: 1 ... 3))),
    .init(name: "oneOf", recipe: .combinator(.oneOf([.leaf(.int(0 ... 5)), .leaf(.int(6 ... 10))]))),
    .init(name: "weightedOneOf", recipe: .combinator(.weightedOneOf([
        .init(weight: 1, recipe: .leaf(.int(0 ... 5))),
        .init(weight: 2, recipe: .leaf(.int(6 ... 10))),
    ]))),
    .init(name: "filtered", recipe: .combinator(.filtered(.leaf(.int(-20 ... 20)), .isEven))),
    .init(name: "resized", recipe: .combinator(.resized(.leaf(.int(0 ... 100)), size: 10))),
    .init(name: "optional", recipe: .combinator(.optional(.leaf(.int(-10 ... 10))))),
    .init(name: "recursive", recipe: .combinator(.recursive(base: .leaf(.int(0 ... 5)), maxDepth: 2))),
    .init(name: "scaledArray", recipe: .combinator(.scaledArray(.leaf(.int(0 ... 5)), lengthRange: 0 ... 3, scaling: .linear))),
    .init(name: "metamorphed", recipe: .combinator(.metamorphed(.leaf(.int(0 ... 5)), .increment))),
    .init(name: "zipped", recipe: .combinator(.zipped(.leaf(.int(-10 ... 10)), .leaf(.int(0 ... 100))))),
    .init(name: "unique", recipe: .combinator(.unique(.leaf(.int(0 ... 1000))))),
    .init(name: "classified", recipe: .combinator(.classified(.leaf(.int(0 ... 10))))),
    .init(name: "boundArray", recipe: .combinator(.boundArray(element: .leaf(.int(0 ... 5)), maxLength: 3))),
]

/// Node-count ceiling for recipes fed to the invariants. Debug builds give each interpreter recursion level a fat stack frame, so total recipe size, not nesting depth alone, is what overflows the 512 KiB test-thread stack. Calibrated empirically with the ExhaustStackProbe executable (2026-07-07, arm64 debug, interpreter case handlers outlined): nested filter chains are the worst shape because every level stacks a CGS tuning pass, crashing between 80 and 96 nodes; mapped, optional, unique, and classified chains all clear 112. The constant is the worst ceiling with a ~2x margin for platform and toolchain variance. Recalibrate with the probe after changing any interpreter's recursion frames or adding a recipe kind with a new nesting shape.
let metaRecipeNodeBudget = 40
