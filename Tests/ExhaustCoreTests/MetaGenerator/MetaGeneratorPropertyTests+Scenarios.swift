import ExhaustCore
import ExhaustTestSupport
import Testing

extension MetaGeneratorPropertyTests {
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
