//
//  MetaGeneratorPropertyTests.swift
//  ExhaustTests
//
//  Property tests that verify Exhaust's core invariants hold across
//  all possible generator structures by generating random generator
//  *recipes* and testing the resulting generators.
//

import ExhaustCore
import Testing

@Suite("Meta-Generator Property Tests")
struct MetaGeneratorPropertyTests {
    /// Recipe generator for Int-producing recipes at depth 2.
    private let intRecipeGen = recipeGenerator(producing: .int, maxDepth: 2)
    /// Recipe generator for Bool-producing recipes at depth 1.
    private let boolRecipeGen = recipeGenerator(producing: .bool, maxDepth: 1)
    /// Recipe generator for simple Int-producing recipes at depth 1.
    private let simpleIntRecipeGen = recipeGenerator(producing: .int, maxDepth: 1)

    // MARK: 1. Reflection Round-Trip

    @Test("Generated generators round-trip through reflect and replay")
    func reflectionRoundTrip() throws {
        var recipeIter = ValueInterpreter(simpleIntRecipeGen, maxRuns: 30)
        while let recipe = try recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, maxRuns: 10)
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

    // MARK: 2. Replay Determinism

    @Test("Replaying the same ChoiceTree produces identical values")
    func replayDeterminism() throws {
        var recipeIter = ValueInterpreter(simpleIntRecipeGen, maxRuns: 30)
        while let recipe = try recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, maxRuns: 10)
            while let (_, tree) = try valueIter.next() {
                let replay1 = try? Interpreters.replay(gen, using: tree)
                let replay2 = try? Interpreters.replay(gen, using: tree)
                guard let r1 = replay1, let r2 = replay2 else { continue }
                #expect(
                    anyEquals(r1, r2),
                    "Replay not deterministic for recipe: \(recipe)"
                )
            }
        }
    }

    // MARK: 3. Materialize Agreement

    @Test("Materialize with flattened tree agrees with replay")
    func materializeAgreement() throws {
        var recipeIter = ValueInterpreter(simpleIntRecipeGen, maxRuns: 30)
        while let recipe = try recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, maxRuns: 10)
            while let (value, _) = try valueIter.next() {
                guard let reflectedTree = try? Interpreters.reflect(gen, with: value) else { continue }
                guard let replayed = try? Interpreters.replay(gen, using: reflectedTree) else { continue }
                let sequence = ChoiceSequence.flatten(reflectedTree)
                guard case let .success(materialized, _, _) = Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: reflectedTree) else { continue }
                #expect(
                    anyEquals(materialized, replayed),
                    "Materialize disagrees with replay for recipe: \(recipe)"
                )
            }
        }
    }

    // MARK: 4. Functor Identity

    @Test("Mapping with identity produces same values")
    func functorIdentity() throws {
        var recipeIter = ValueInterpreter(simpleIntRecipeGen, maxRuns: 30)
        while let recipe = try recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            // contramap(id, gen.map(id)) adds no PRNG-consuming operations
            let mappedGen: ReflectiveGenerator<Any> = Gen.contramap(
                { (newOutput: Any) throws -> Any in newOutput },
                gen._map { $0 }
            )

            var iter1: ValueInterpreter<Any> = ValueInterpreter(gen, seed: 42, maxRuns: 10)
            var iter2: ValueInterpreter<Any> = ValueInterpreter(mappedGen, seed: 42, maxRuns: 10)

            while let v1 = try iter1.next(), let v2 = try iter2.next() {
                #expect(
                    anyEquals(v1, v2),
                    "Functor identity failed for recipe: \(recipe)"
                )
            }
        }
    }

    // MARK: 5. Functor Composition

    @Test("map(f).map(g) produces same values as map(g . f)")
    func functorComposition() throws {
        // Use Int recipes so we can apply Int->Int transforms
        let intLeafGen = recipeGenerator(producing: .int, maxDepth: 0)
        var recipeIter = ValueInterpreter(intLeafGen, maxRuns: 30)
        while let recipe = try recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            let f: (Any) -> Any = { ($0 as! Int) * 2 }
            let g: (Any) -> Any = { ($0 as! Int) + 1 }

            // gen.map(f).map(g)
            let composed1 = gen._map(f)._map(g)
            // gen.map(g . f)
            let composed2 = gen._map { g(f($0)) }

            var iter1 = ValueInterpreter(composed1, seed: 42, maxRuns: 10)
            var iter2 = ValueInterpreter(composed2, seed: 42, maxRuns: 10)

            while let v1 = try iter1.next(), let v2 = try iter2.next() {
                #expect(
                    anyEquals(v1, v2),
                    "Functor composition failed for recipe: \(recipe)"
                )
            }
        }
    }

    // MARK: 6. Monad Left Identity

    @Test("just(x).bind(f) produces same values as f(x)")
    func monadLeftIdentity() throws {
        var valueIter = ValueInterpreter(Gen.choose(in: -100 ... 100 as ClosedRange<Int>), seed: 7, maxRuns: 30)
        while let x = try valueIter.next() {
            let f: (Int) -> ReflectiveGenerator<Int> = { val in
                Gen.choose(in: val ... (val + 10))
            }

            let lhs: ReflectiveGenerator<Int> = Gen.just(x)._bind { f($0) }
            let rhs: ReflectiveGenerator<Int> = f(x)

            var lhsIter = ValueInterpreter(lhs, seed: 99, maxRuns: 5)
            var rhsIter = ValueInterpreter(rhs, seed: 99, maxRuns: 5)

            while let v1 = try lhsIter.next(), let v2 = try rhsIter.next() {
                #expect(v1 == v2, "Monad left identity failed for x=\(x)")
            }
        }
    }

    // MARK: 7. Monad Right Identity

    @Test("gen.bind(just) produces same values as gen")
    func monadRightIdentity() throws {
        let intLeafGen = recipeGenerator(producing: .int, maxDepth: 0)
        var recipeIter = ValueInterpreter(intLeafGen, maxRuns: 30)
        while let recipe = try recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            // bind { .pure($0) } adds no PRNG-consuming operations
            let boundGen = gen._bind { .pure($0) }

            var iter1 = ValueInterpreter(gen, seed: 42, maxRuns: 10)
            var iter2 = ValueInterpreter(boundGen, seed: 42, maxRuns: 10)

            while let v1 = try iter1.next(), let v2 = try iter2.next() {
                #expect(
                    anyEquals(v1, v2),
                    "Monad right identity failed for recipe: \(recipe)"
                )
            }
        }
    }

    // MARK: 8. Shrinking Preserves Failure

    @Test("Shrunk values still fail the original property")
    func shrinkingPreservesFailure() throws {
        // Use simple Int recipes to test shrinking
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
                guard let (_, shrunk) = try? Interpreters.choiceGraphReduce(
                    gen: gen, tree: tree, config: .fast, property: property
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
        // Generate Int recipes and apply known predicates
        let intLeafGen = recipeGenerator(producing: .int, maxDepth: 0)
        var recipeIter = ValueInterpreter(intLeafGen, maxRuns: 20)
        while let recipe = try recipeIter.next() {
            // Only use predicates applicable to the recipe's output type
            for predicate in KnownPredicate.applicable(to: recipe.outputType) {
                // For .isPositive, constrain the inner recipe to include positive values
                let innerGen: ReflectiveGenerator<Any>
                if predicate == .isPositive {
                    innerGen = Gen.choose(in: -10 ... 100 as ClosedRange<Int>).erase()
                } else if predicate == .isNonEmpty {
                    continue // Skip — doesn't apply to leaf int
                } else {
                    innerGen = buildGenerator(from: recipe)
                }

                let filteredGen: ReflectiveGenerator<Any> = .impure(
                    operation: .filter(gen: innerGen.erase(), fingerprint: 0, filterType: .auto, predicate: { predicate.evaluate($0) }),
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
        var recipeIter = ValueInterpreter(intRecipeGen, maxRuns: 30)
        while let recipe = try recipeIter.next() {
            // Extract the range from leaf Int recipes for direct validation
            guard case let .leaf(.int(range)) = recipe else { continue }
            let gen = Gen.choose(in: range)

            var valueIter = ValueInterpreter(gen, maxRuns: 20)
            while let value = try valueIter.next() {
                #expect(
                    range.contains(value),
                    "Value \(value) outside range \(range)"
                )
            }
        }
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

    // MARK: 13. Random Recipes with Just/Zip

    @Test("Random recipes with just and zip round-trip through reflect and replay", .disabled("This blows the stack when ran repeatedly"))
    func randomJustZipRecipesRoundTrip() throws {
        // Use depth 2 to get combinations of just, zip, and other combinators
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
