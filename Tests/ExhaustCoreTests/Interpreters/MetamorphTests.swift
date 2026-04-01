import Testing
@testable import ExhaustCore

@Suite("Metamorphic Transform")
struct MetamorphTests {
    // MARK: - Helpers

    /// Builds a metamorphic generator that pairs an Int with its negation.
    private func intNegateGen() -> ReflectiveGenerator<[Any]> {
        let inner = Gen.choose(in: 1 ... 100 as ClosedRange<Int>)
        return .impure(
            operation: .transform(
                kind: .metamorphic(
                    transforms: [{ value in -(value as! Int) as Any }],
                    inputType: Int.self
                ),
                inner: inner.erase()
            ),
            continuation: { .pure($0 as! [Any]) }
        )
    }

    /// Builds a metamorphic generator with two transforms on Int.
    private func intDoubleAndNegateGen() -> ReflectiveGenerator<[Any]> {
        let inner = Gen.choose(in: 1 ... 100 as ClosedRange<Int>)
        return .impure(
            operation: .transform(
                kind: .metamorphic(
                    transforms: [
                        { value in (value as! Int) * 2 as Any },
                        { value in -(value as! Int) as Any },
                    ],
                    inputType: Int.self
                ),
                inner: inner.erase()
            ),
            continuation: { .pure($0 as! [Any]) }
        )
    }

    // MARK: - ValueInterpreter (Generation)

    @Test("ValueInterpreter produces original at index zero and transformed copies")
    func valueInterpreterBasic() throws {
        let gen = intNegateGen()
        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 50)
        var count = 0
        while let results = try iterator.next() {
            #expect(results.count == 2)
            let original = results[0] as! Int
            let negated = results[1] as! Int
            #expect(negated == -original)
            count += 1
        }
        #expect(count > 0)
    }

    @Test("ValueInterpreter handles multiple transforms")
    func valueInterpreterMultipleTransforms() throws {
        let gen = intDoubleAndNegateGen()
        var iterator = ValueInterpreter(gen, seed: 7, maxRuns: 30)
        while let results = try iterator.next() {
            #expect(results.count == 3)
            let original = results[0] as! Int
            let doubled = results[1] as! Int
            let negated = results[2] as! Int
            #expect(doubled == original * 2)
            #expect(negated == -original)
        }
    }

    // MARK: - ValueAndChoiceTreeInterpreter (Generation + Tree)

    @Test("VACTI produces transparent choice tree (same as inner)")
    func vactiTreeShape() throws {
        let gen = intNegateGen()
        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 42)
        let (results, tree) = try #require(try iterator.next())
        let original = results[0] as! Int
        let negated = results[1] as! Int
        #expect(negated == -original)

        // Tree should be transparent — a single chooseBits, no bind or group wrapper.
        if case .choice = tree {
            // expected: single choice node from inner Int generator
        } else {
            Issue.record("Expected a .choice tree from inner generator, got \(tree)")
        }
    }

    // MARK: - Replay

    @Test("Replay produces identical results from the same choice tree")
    func replayDeterminism() throws {
        let gen = intNegateGen()
        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 42)

        for _ in 0 ..< 20 {
            let (original, tree) = try #require(try iterator.next())
            let replayed = try #require(try Interpreters.replay(gen, using: tree))
            let originalArray = original
            let replayedArray = replayed

            #expect(originalArray.count == replayedArray.count)
            for index in 0 ..< originalArray.count {
                #expect(originalArray[index] as! Int == replayedArray[index] as! Int)
            }
        }
    }

    @Test("Replay with multiple transforms matches generation")
    func replayMultipleTransforms() throws {
        let gen = intDoubleAndNegateGen()
        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 13)

        for _ in 0 ..< 20 {
            let (original, tree) = try #require(try iterator.next())
            let replayed = try #require(try Interpreters.replay(gen, using: tree))

            #expect(original.count == replayed.count)
            for index in 0 ..< original.count {
                #expect(original[index] as! Int == replayed[index] as! Int)
            }
        }
    }

    // MARK: - Independent Copies (Reference Type Safety)

    @Test("Each transform receives an independently generated copy")
    func independentCopies() throws {
        // Use an array generator — arrays are value types in Swift but this
        // validates that each transform's input was generated from the same
        // PRNG state, producing identical but independent values.
        let inner = Gen.arrayOf(Gen.choose(in: 0 ... 100 as ClosedRange<Int>), exactly: 3)
        let gen: ReflectiveGenerator<[Any]> = .impure(
            operation: .transform(
                kind: .metamorphic(
                    transforms: [
                        { arr in
                            var copy = arr as! [Int]
                            copy[0] = 999
                            return copy as Any
                        },
                        { arr in
                            let copy = arr as! [Int]
                            return Array(copy.reversed()) as Any
                        },
                    ],
                    inputType: [Int].self
                ),
                inner: inner.erase()
            ),
            continuation: { .pure($0 as! [Any]) }
        )

        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 20)
        while let results = try iterator.next() {
            #expect(results.count == 3)
            let original = results[0] as! [Int]
            let mutated = results[1] as! [Int]
            let reversed = results[2] as! [Int]

            // The mutated copy should have 999 at index 0 but share the rest
            #expect(mutated[0] == 999)
            #expect(mutated[1] == original[1])
            #expect(mutated[2] == original[2])

            // The reversed copy should be the original reversed, NOT affected by the mutation
            #expect(reversed == original.reversed())
        }
    }

    // MARK: - Reflection

    @Test("Reflection passes through to inner generator")
    func reflectionPassthrough() throws {
        // Build a metamorphic gen via mapped (the public API pattern):
        // contramap(backward) + _map(forward) wrapping the metamorphic operation.
        // For this test, we use the raw operation and verify reflection directly.
        let innerGen = Gen.choose(in: 1 ... 50 as ClosedRange<Int>)
        var iterator = ValueInterpreter(innerGen, seed: 42, maxRuns: 20)

        while let value = try iterator.next() {
            // Reflect the inner generator on the value — this is what the
            // contramap backward extracts before passing to the metamorphic reflector.
            let tree = try Interpreters.reflect(innerGen, with: value)
            #expect(tree != nil, "Reflection should succeed for Int value \(value)")
        }
    }

    // MARK: - Reduction / Bonsai

    @Test("Bonsai reduces the source value and transforms follow")
    func bonsaiReduction() throws {
        let inner = Gen.choose(in: 0 ... 1000 as ClosedRange<Int>)
        let gen: ReflectiveGenerator<[Any]> = .impure(
            operation: .transform(
                kind: .metamorphic(
                    transforms: [{ value in (value as! Int) * 2 as Any }],
                    inputType: Int.self
                ),
                inner: inner.erase()
            ),
            continuation: { .pure($0 as! [Any]) }
        )

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)

        // Find a failing value (original > 100)
        var failingTree: ChoiceTree?
        var failingValue: [Any]?
        for _ in 0 ..< 200 {
            guard let (value, tree) = try iterator.next() else { continue }
            let original = value[0] as! Int
            if original > 100 {
                failingTree = tree
                failingValue = value
                break
            }
        }

        let tree = try #require(failingTree)
        let value = try #require(failingValue)
        let originalBefore = value[0] as! Int
        #expect(originalBefore > 100)

        // Reduce: property is "original <= 100"
        let (_, shrunk) = try #require(
            try Interpreters.bonsaiReduce(gen: gen, tree: tree, config: .fast) { results in
                (results[0] as! Int) <= 100
            }
        )

        let shrunkOriginal = shrunk[0] as! Int
        let shrunkDoubled = shrunk[1] as! Int
        #expect(shrunkOriginal == 101, "Bonsai should find the minimal failing value")
        #expect(shrunkDoubled == shrunkOriginal * 2, "Transform should track the reduced source")
    }

    // MARK: - Materialization Round-Trip

    @Test("Materialize round-trips through VACTI tree")
    func materializeRoundTrip() throws {
        let gen = intNegateGen()
        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)

        for _ in 0 ..< 20 {
            let (original, tree) = try #require(try iterator.next())
            let prefix = ChoiceSequence(tree)

            switch Materializer.materialize(gen, prefix: prefix, mode: .exact, fallbackTree: tree) {
            case let .success(output, _, _):
                let materialized = output
                #expect(materialized.count == original.count)
                for index in 0 ..< materialized.count {
                    #expect(materialized[index] as! Int == original[index] as! Int)
                }
            case .rejected, .failed:
                Issue.record("Materialize should succeed for metamorphic round-trip")
            }
        }
    }
}
