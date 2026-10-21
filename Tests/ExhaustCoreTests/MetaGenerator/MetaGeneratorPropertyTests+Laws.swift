import ExhaustCore
import ExhaustTestSupport
import Testing

extension MetaGeneratorPropertyTests {
    // MARK: - Functor Identity

    @Test("Mapping with identity produces same values")
    func functorIdentity() throws {
        let tally = Tally()
        let badRecipe = try findMinimalCounterexample(recipeGenerator(producing: .int, maxDepth: 1), maxIterations: 50) { recipe in
            let gen = buildGenerator(from: recipe)
            let mappedGen: AnyGenerator = Gen.contramap(
                { (newOutput: Any) throws -> Any in newOutput },
                gen.map(\.self)
            )
            let comparison = checkPairedValues(gen, mappedGen, maxRuns: 10) { v1, v2 in
                anyEquals(v1, v2)
            }
            tally.evaluated += comparison.evaluated
            return comparison.matches
        }
        #expect(badRecipe == nil, "Functor identity failed for minimal recipe: \(badRecipe!)")
        #expect(tally.evaluated > 0, "No value pairs were compared")
    }

    // MARK: - Functor Composition

    @Test("map(f).map(g) produces same values as map(g . f)")
    func functorComposition() throws {
        let tally = Tally()
        let intLeafGen = recipeGenerator(producing: .int, maxDepth: 0)
        let badRecipe = try findMinimalCounterexample(intLeafGen, maxIterations: 50) { recipe in
            let gen = buildGenerator(from: recipe)
            let f: (Any) -> Any = { ($0 as! Int) * 2 }
            let g: (Any) -> Any = { ($0 as! Int) + 1 }
            let composed1 = gen.map(f).map(g)
            let composed2 = gen.map { g(f($0)) }
            let comparison = checkPairedValues(composed1, composed2, maxRuns: 10) { v1, v2 in
                anyEquals(v1, v2)
            }
            tally.evaluated += comparison.evaluated
            return comparison.matches
        }
        #expect(badRecipe == nil, "Functor composition failed for minimal recipe: \(badRecipe!)")
        #expect(tally.evaluated > 0, "No value pairs were compared")
    }

    // MARK: - Monad Left Identity

    @Test("just(x).bind(f) produces same values as f(x)")
    func monadLeftIdentity() throws {
        let badValue = try findMinimalCounterexample(
            Gen.choose(in: -100 ... 100 as ClosedRange<Int>),
            maxIterations: 50, seed: 7
        ) { x in
            let f: (Int) -> Generator<Int> = { val in Gen.choose(in: val ... (val + 10)) }
            let lhs: Generator<Int> = Gen.just(x).bind { f($0) }
            let rhs: Generator<Int> = f(x)
            let comparison = checkPairedValues(lhs.erase(), rhs.erase(), seed: 99, maxRuns: 5, check: anyEquals)
            return comparison.matches && comparison.evaluated == 5
        }
        #expect(badValue == nil, "Monad left identity failed for x=\(badValue!)")
    }

    // MARK: - Monad Right Identity

    @Test("gen.bind(just) produces same values as gen")
    func monadRightIdentity() throws {
        let tally = Tally()
        let intLeafGen = recipeGenerator(producing: .int, maxDepth: 0)
        let badRecipe = try findMinimalCounterexample(intLeafGen, maxIterations: 50) { recipe in
            let gen = buildGenerator(from: recipe)
            let boundGen = gen.bind { .pure($0) }
            let comparison = checkPairedValues(gen, boundGen, maxRuns: 10) { v1, v2 in
                anyEquals(v1, v2)
            }
            tally.evaluated += comparison.evaluated
            return comparison.matches
        }
        #expect(badRecipe == nil, "Monad right identity failed for minimal recipe: \(badRecipe!)")
        #expect(tally.evaluated > 0, "No value pairs were compared")
    }

    // MARK: - Filter Correctness

    @Test("Filtered generators only produce values satisfying the predicate")
    func filterCorrectness() throws {
        let intLeafGen = recipeGenerator(producing: .int, maxDepth: 0)
        var recipeIter = ValueInterpreter(intLeafGen, seed: 42, maxRuns: 20)
        for _ in 0 ..< 20 {
            let recipe = try #require(try recipeIter.next())
            for predicate in KnownPredicate.applicable(to: recipe.outputType) {
                let innerGenerator = predicate == .isPositive
                    ? Gen.choose(in: -10 ... 100 as ClosedRange<Int>).erase()
                    : buildGenerator(from: recipe)

                let filteredGen: AnyGenerator = .impure(
                    operation: .filter(
                        gen: innerGenerator,
                        fingerprint: Gen.sourceFingerprint(fileID: #fileID, line: #line, column: #column),
                        filterType: .auto,
                        predicate: { predicate.evaluate($0) },
                        sourceLocation: FilterSourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
                    ),
                    continuation: { .pure($0) }
                )

                var valueIter = ValueInterpreter(filteredGen, seed: 42, maxRuns: 15)
                for _ in 0 ..< 15 {
                    let value = try #require(try valueIter.next())
                    #expect(
                        predicate.evaluate(value),
                        "Filter \(predicate) violated for recipe: \(recipe)"
                    )
                }
            }
        }
    }

    // MARK: - Size Bounds

    @Test("Numeric generation stays inside arbitrary ordered endpoint pairs")
    func sizeBounds() throws {
        let endpoints = Gen.zip(
            Gen.choose(in: Int.min ... Int.max),
            Gen.choose(in: Int.min ... Int.max)
        )
        try exhaustCheck(endpoints, maxIterations: 100) { first, second in
            let range = min(first, second) ... max(first, second)
            var interpreter = ValueInterpreter(Gen.choose(in: range), seed: 42, maxRuns: 20)
            for _ in 0 ..< 20 {
                let value = try #require(try interpreter.next())
                #expect(range.contains(value))
            }
            return true
        }
    }
}
