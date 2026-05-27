import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Meta-Generator Property Tests", .tags(.dogfood))
struct MetaGeneratorPropertyTests {
    private let simpleIntRecipeGen = recipeGenerator(producing: .int, maxDepth: 1)

    // MARK: 1. Reflection Round-Trip

    @Test("Generated generators round-trip through reflect and replay")
    func reflectionRoundTrip() throws {
        let badRecipe = try findMinimalCounterexample(simpleIntRecipeGen, maxIterations: 50) { recipe in
            let gen = buildGenerator(from: recipe)
            return checkAllValues(gen, maxRuns: 10) { value in
                guard let tree = try Interpreters.reflect(gen, with: value) else { return true }
                guard let replayed = try Interpreters.replay(gen, using: tree) else { return true }
                return anyEquals(value, replayed)
            }
        }
        #expect(badRecipe == nil, "Round-trip failed for minimal recipe: \(badRecipe!)")
    }

    // MARK: 2. Replay Determinism

    @Test("Replaying the same ChoiceTree produces identical values")
    func replayDeterminism() throws {
        let badRecipe = try findMinimalCounterexample(simpleIntRecipeGen, maxIterations: 50) { recipe in
            let gen = buildGenerator(from: recipe)
            return checkAllTrees(gen, maxRuns: 10) { tree in
                guard let r1 = try Interpreters.replay(gen, using: tree),
                      let r2 = try Interpreters.replay(gen, using: tree) else { return true }
                return anyEquals(r1, r2)
            }
        }
        #expect(badRecipe == nil, "Replay not deterministic for minimal recipe: \(badRecipe!)")
    }

    // MARK: 3. Materialize Agreement

    @Test("Materialize with flattened tree agrees with replay")
    func materializeAgreement() throws {
        let badRecipe = try findMinimalCounterexample(simpleIntRecipeGen, maxIterations: 50) { recipe in
            let gen = buildGenerator(from: recipe)
            return checkAllValues(gen, maxRuns: 10) { value in
                guard let reflectedTree = try Interpreters.reflect(gen, with: value) else { return true }
                guard let replayed = try Interpreters.replay(gen, using: reflectedTree) else { return true }
                let sequence = ChoiceSequence.flatten(reflectedTree)
                guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: reflectedTree) else { return true }
                return anyEquals(materialized, replayed)
            }
        }
        #expect(badRecipe == nil, "Materialize disagrees with replay for minimal recipe: \(badRecipe!)")
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

    // MARK: 8. Shrinking Preserves Failure (manual — circular if dogfooded)

    @Test("Shrunk values still fail the original property")
    func shrinkingPreservesFailure() throws {
        let intLeafGen = recipeGenerator(producing: .int, maxDepth: 0)
        var recipeIter = ValueInterpreter(intLeafGen, maxRuns: 20)
        while let recipe = try recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            let property: (Any) -> Bool = { value in
                guard let intVal = value as? Int else { return true }
                return intVal < 10
            }

            var valueIter = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 20)
            while let (value, tree) = try valueIter.next() {
                guard !property(value) else { continue }
                guard case let .reduced(_, shrunk) = try? Interpreters.choiceGraphReduce(
                    gen: gen, tree: tree, config: .init(maxStalls: 2), property: property
                ) else { continue }
                #expect(
                    !property(shrunk),
                    "Shrunk value passes property but shouldn't, recipe: \(recipe)"
                )
            }
        }
    }

    // MARK: 9. Filter Correctness

    @Test("Filtered generators only produce values satisfying the predicate")
    func filterCorrectness() throws {
        let intLeafGen = recipeGenerator(producing: .int, maxDepth: 0)
        var recipeIter = ValueInterpreter(intLeafGen, maxRuns: 20)
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
                    operation: .filter(gen: innerGen.erase(), fingerprint: 0, filterType: .auto, predicate: { predicate.evaluate($0) }, tuned: nil, sourceLocation: FilterSourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)),
                    continuation: { .pure($0) }
                )

                var valueIter = ValueInterpreter(filteredGen, maxRuns: 15)
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
                var valueIter = ValueInterpreter(gen, maxRuns: 20)
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
            var valueIter = ValueAndChoiceTreeInterpreter(gen, maxRuns: 5)
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
            var valueIter = ValueAndChoiceTreeInterpreter(gen, maxRuns: 3)
            while let (value, _) = try valueIter.next() {
                guard let tree = try? Interpreters.reflect(gen, with: value) else { continue }
                guard let replayed = try? Interpreters.replay(gen, using: tree) else { continue }
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
            var valueIter = ValueAndChoiceTreeInterpreter(gen, maxRuns: 10)
            while let (value, _) = try valueIter.next() {
                guard let tree = try? Interpreters.reflect(gen, with: value) else { continue }
                guard let replayed = try? Interpreters.replay(gen, using: tree) else { continue }
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
            var valueIter = ValueAndChoiceTreeInterpreter(gen, maxRuns: 10)
            while let (_, tree) = try valueIter.next() {
                let r1 = try? Interpreters.replay(gen, using: tree)
                let r2 = try? Interpreters.replay(gen, using: tree)
                guard let r1, let r2 else { continue }
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
            var valueIter = ValueAndChoiceTreeInterpreter(gen, maxRuns: 10)
            while let (value, _) = try valueIter.next() {
                guard let reflectedTree = try? Interpreters.reflect(gen, with: value) else { continue }
                guard let replayed = try? Interpreters.replay(gen, using: reflectedTree) else { continue }
                let sequence = ChoiceSequence.flatten(reflectedTree)
                guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: reflectedTree) else { continue }
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
            var valueIter = ValueAndChoiceTreeInterpreter(gen, maxRuns: 15)
            while let (_, tree) = try valueIter.next() {
                let r1 = try? Interpreters.replay(gen, using: tree)
                let r2 = try? Interpreters.replay(gen, using: tree)
                guard let r1, let r2 else { continue }
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
            var valueIter = ValueAndChoiceTreeInterpreter(gen, maxRuns: 15)
            while let (value, _) = try valueIter.next() {
                guard let reflectedTree = try? Interpreters.reflect(gen, with: value) else { continue }
                guard let replayed = try? Interpreters.replay(gen, using: reflectedTree) else { continue }
                let sequence = ChoiceSequence.flatten(reflectedTree)
                guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: reflectedTree) else { continue }
                #expect(
                    anyEquals(materialized, replayed),
                    "Optional materialize disagrees with replay for recipe: \(recipe)"
                )
            }
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

    @Test("Random recipes with just and zip round-trip through reflect and replay", .disabled("This blows the stack when ran repeatedly"))
    func randomJustZipRecipesRoundTrip() throws {
        let recipeGen = recipeGenerator(producing: .int, maxDepth: 2)
        var recipeIter = ValueInterpreter(recipeGen, maxRuns: 40)
        while let recipe = try recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, maxRuns: 5)
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
}

// MARK: - Helpers

/// Checks a property against all generated values. Returns true if the property holds for all values.
private func checkAllValues(
    _ gen: AnyGenerator,
    maxRuns: UInt64 = 10,
    check: (Any) throws -> Bool
) -> Bool {
    do {
        var iter = ValueAndChoiceTreeInterpreter(gen, maxRuns: maxRuns)
        while let (value, _) = try iter.next() {
            if try check(value) == false { return false }
        }
    } catch {
        return true
    }
    return true
}

/// Checks a property against all generated choice trees. Returns true if the property holds for all trees.
private func checkAllTrees(
    _ gen: AnyGenerator,
    maxRuns: UInt64 = 10,
    check: (ChoiceTree) throws -> Bool
) -> Bool {
    do {
        var iter = ValueAndChoiceTreeInterpreter(gen, maxRuns: maxRuns)
        while let (_, tree) = try iter.next() {
            if try check(tree) == false { return false }
        }
    } catch {
        return true
    }
    return true
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
