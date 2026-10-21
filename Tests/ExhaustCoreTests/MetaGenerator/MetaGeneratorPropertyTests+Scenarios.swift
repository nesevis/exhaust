import ExhaustCore
import ExhaustTestSupport
import Testing

extension MetaGeneratorPropertyTests {
    // MARK: 11. Just Values

    @Test("Constant recipes preserve their literal through generation, reflection, replay and materialization")
    func justValuesAreConstant() throws {
        let fixtures: [(GenRecipe.LeafKind, Any)] = [
            (.justInt(42), 42), (.justInt(-7), -7), (.justInt(0), 0),
            (.justBool(true), true), (.justBool(false), false), (.justDouble(3.14), 3.14),
            (.justIntArray([1, 2, 3]), [1, 2, 3]), (.justIntArray([10, 20]), [10, 20]),
            (.justIntArray([]), [Int]()),
        ]
        for (leaf, expected) in fixtures {
            try checkRecipeRoundTrips(.leaf(leaf), samples: 5) { value in
                #expect(anyEquals(value, expected))
            }
        }
    }

    @Test("Zip and optional recipes preserve generated values through all reconstruction paths")
    func composedRecipeRoundTrips() throws {
        let recipes: [GenRecipe] = [
            .combinator(.zipped(.leaf(.int(-10 ... 10)), .leaf(.int(0 ... 100)))),
            .combinator(.zipped(.leaf(.justInt(5)), .leaf(.int(-5 ... 5)))),
            .combinator(.zipped(.leaf(.bool), .leaf(.bool))),
            .combinator(.optional(.leaf(.int(0 ... 100)))),
            .combinator(.optional(.leaf(.justInt(5)))),
        ]
        for recipe in recipes {
            try checkRecipeRoundTrips(recipe, samples: 15)
        }
    }

    // MARK: 12. Zipped Generators

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
                if sawNil, sawSome {
                    break
                }
            }
            #expect(sawNil, "Optional recipe \(recipe) never produced nil")
            #expect(sawSome, "Optional recipe \(recipe) never produced a value")
        }
    }

    @Test("Nested optionals reconstruct nil-bearing values at multiple depths")
    func nestedOptionalReflectionRoundTrip() throws {
        let recipes: [GenRecipe] = [
            .combinator(.optional(.combinator(.optional(.leaf(.int(-10 ... 10)))))),
            .combinator(.optional(.combinator(.optional(.combinator(.optional(.leaf(.justInt(7)))))))),
        ]
        for recipe in recipes {
            var sawNilBearing = false
            try checkRecipeRoundTrips(recipe, samples: 60) { value in
                sawNilBearing = sawNilBearing || containsNil(value)
            }
            #expect(sawNilBearing, "The sweep must exercise nil-bearing values: \(recipe)")
        }
    }

    @Test("Optional getSize reflection rejects incompatible branch probes without trapping")
    func optionalGetSizeReflectionIsCrashSafe() throws {
        let recipe = GenRecipe.combinator(.optional(.combinator(.getSized)))
        let generator = buildGenerator(from: recipe)
        let value = Any?.some(3) as Any

        let tree = try #require(try Interpreters.reflect(generator, with: value))
        let replayed = try #require(try Interpreters.replay(generator, using: tree))

        #expect(anyEquals(replayed, value))
    }

    // MARK: 14. Per-Combinator Reflection Coverage

    /// Asserts every reflectable combinator actually reflects and round-trips at least one of its own generated values.
    ///
    /// The round-trip sweeps skip any value whose generator fails to reflect (`catch { return true }` in `checkAllValues`, `else { continue }` in the fixture tests), so a combinator that silently stopped reflecting would leave those tests green. Zip did exactly this for months: a projecting `.map` made its output unreflectable and every zip assertion was skipped unseen. Each fixture here uses `#require`, so any regression that breaks a reflectable combinator fails loudly rather than passing vacuously. `boundRange` and `unfolded` are excluded because their bind/unfold construction is forward-only, so nil reflection is expected for them, not a defect.
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

    // MARK: 15. Forward-Only Exemption (pinned)

    /// Pins the combinators the coverage sweep deliberately omits, so their exemption is an assertion rather than silence.
    ///
    /// `unfolded` builds a `bindReified` chain with no backward, so reflection throws for every value. `boundRange` is a reified bind with no backward, because the lower bound cannot be recovered from a value drawn above it. Both are excluded from ``reflectableCombinatorFixtures`` because a nil or thrown reflection is expected, not a defect. Asserting that here means that if backward support is ever added, making these reflect, this test fails and prompts promoting the kind into the reflectable set and the round-trip sweeps.
    @Test("Forward-only combinators stay unreflectable")
    func forwardOnlyCombinatorsStayUnreflectable() throws {
        let unfolded: GenRecipe = .combinator(.unfolded(depthRange: 0 ... 3))
        let unfoldedReflected = try reflectableValueCount(unfolded, seed: 42, maxRuns: 12)
        #expect(unfoldedReflected == 0, "unfolded reflected \(unfoldedReflected)/12 values. It is now reflectable, so promote it into reflectableCombinatorFixtures and the round-trip sweeps")

        let boundRange: GenRecipe = .combinator(.boundRange(.leaf(.int(0 ... 10))))
        let boundRangeReflected = try reflectableValueCount(boundRange, seed: 42, maxRuns: 12)
        #expect(boundRangeReflected < 12, "boundRange reflected all 12 values. It is now fully reflectable, so promote it into reflectableCombinatorFixtures and the round-trip sweeps")
    }
}

// MARK: - Helpers

private func checkRecipeRoundTrips(
    _ recipe: GenRecipe,
    samples: UInt64,
    check: (Any) -> Void = { _ in }
) throws {
    let generator = buildGenerator(from: recipe)
    var interpreter = ValueAndChoiceTreeInterpreter(generator, seed: 42, maxRuns: samples)
    for _ in 0 ..< samples {
        let (value, _) = try #require(try interpreter.next(), "No value generated for \(recipe)")
        check(value)
        let tree = try #require(try Interpreters.reflect(generator, with: value), "Must reflect: \(recipe)")
        let replayed = try #require(try Interpreters.replay(generator, using: tree), "Must replay: \(recipe)")
        #expect(anyEquals(value, replayed), "Replay changed value: \(recipe)")
        guard case let .success(materialized, _, _) = Materializer.materialize(generator, context: .init(
            prefix: ChoiceSequence(tree), mode: .exact, fallbackTree: tree
        )) else {
            Issue.record("Must materialize: \(recipe)")
            continue
        }
        #expect(anyEquals(value, materialized), "Materialization changed value: \(recipe)")
    }
}
