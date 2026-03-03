//
//  MetaGeneratorPropertyTests.swift
//  ExhaustTests
//
//  Property tests that verify Exhaust's core invariants hold across
//  all possible generator structures by generating random generator
//  *recipes* and testing the resulting generators.
//

import Testing
@testable import Exhaust
@testable @_spi(ExhaustInternal) import ExhaustCore

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
        while let recipe = recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, maxRuns: 10)
            while let (value, _) = valueIter.next() {
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
        while let recipe = recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, maxRuns: 10)
            while let (_, tree) = valueIter.next() {
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
        while let recipe = recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, maxRuns: 10)
            while let (value, _) = valueIter.next() {
                guard let reflectedTree = try? Interpreters.reflect(gen, with: value) else { continue }
                guard let replayed = try? Interpreters.replay(gen, using: reflectedTree) else { continue }
                let sequence = ChoiceSequence.flatten(reflectedTree)
                guard let materialized = try? Interpreters.materialize(gen, with: reflectedTree, using: sequence) else { continue }
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
        while let recipe = recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            // mapped(forward: id, backward: id) adds no PRNG-consuming operations
            let mappedGen = gen.mapped(
                forward: { $0 },
                backward: { $0 }
            )

            var iter1 = ValueInterpreter(gen, seed: 42, maxRuns: 10)
            var iter2 = ValueInterpreter(mappedGen, seed: 42, maxRuns: 10)

            while let v1 = iter1.next(), let v2 = iter2.next() {
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
        while let recipe = recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            let f: (Any) -> Any = { ($0 as! Int) * 2 }
            let g: (Any) -> Any = { ($0 as! Int) + 1 }

            // gen.map(f).map(g)
            let composed1 = gen.map(f).map(g)
            // gen.map(g . f)
            let composed2 = gen.map { g(f($0)) }

            var iter1 = ValueInterpreter(composed1, seed: 42, maxRuns: 10)
            var iter2 = ValueInterpreter(composed2, seed: 42, maxRuns: 10)

            while let v1 = iter1.next(), let v2 = iter2.next() {
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
        while let x = valueIter.next() {
            let f: (Int) -> ReflectiveGenerator<Int> = { val in
                Gen.choose(in: val ... (val + 10))
            }

            let lhs: ReflectiveGenerator<Int> = ReflectiveGenerator<Int>.just(x).bind { f($0) }
            let rhs: ReflectiveGenerator<Int> = f(x)

            var lhsIter = ValueInterpreter(lhs, seed: 99, maxRuns: 5)
            var rhsIter = ValueInterpreter(rhs, seed: 99, maxRuns: 5)

            while let v1 = lhsIter.next(), let v2 = rhsIter.next() {
                #expect(v1 == v2, "Monad left identity failed for x=\(x)")
            }
        }
    }

    // MARK: 7. Monad Right Identity

    @Test("gen.bind(just) produces same values as gen")
    func monadRightIdentity() throws {
        let intLeafGen = recipeGenerator(producing: .int, maxDepth: 0)
        var recipeIter = ValueInterpreter(intLeafGen, maxRuns: 30)
        while let recipe = recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            // bind { .pure($0) } adds no PRNG-consuming operations
            let boundGen = gen.bind { .pure($0) }

            var iter1 = ValueInterpreter(gen, seed: 42, maxRuns: 10)
            var iter2 = ValueInterpreter(boundGen, seed: 42, maxRuns: 10)

            while let v1 = iter1.next(), let v2 = iter2.next() {
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
        while let recipe = recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            let property: (Any) -> Bool = { value in
                guard let intVal = value as? Int else { return true }
                return intVal < 10
            }

            var valueIter = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 20)
            while let (value, tree) = valueIter.next() {
                guard !property(value) else { continue }
                guard let (_, shrunk) = try? Interpreters.reduce(
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
        while let recipe = recipeIter.next() {
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

                let filteredGen = innerGen.filter { predicate.evaluate($0) }

                var valueIter = ValueInterpreter(filteredGen, maxRuns: 15)
                while let value = valueIter.next() {
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
        while let recipe = recipeIter.next() {
            // Extract the range from leaf Int recipes for direct validation
            guard case let .leaf(.int(range)) = recipe else { continue }
            let gen = Gen.choose(in: range)

            var valueIter = ValueInterpreter(gen, maxRuns: 20)
            while let value = valueIter.next() {
                #expect(
                    range.contains(value),
                    "Value \(value) outside range \(range)"
                )
            }
        }
    }
}
