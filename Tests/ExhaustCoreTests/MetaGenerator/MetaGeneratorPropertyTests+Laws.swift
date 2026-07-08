import ExhaustCore
import ExhaustTestSupport
import Testing

extension MetaGeneratorPropertyTests {
    // MARK: 4. Functor Identity

    @Test("Mapping with identity produces same values")
    func functorIdentity() throws {
        let badRecipe = try findMinimalCounterexample(recipeGenerator(producing: .int, maxDepth: 1), maxIterations: 50) { recipe in
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
}
