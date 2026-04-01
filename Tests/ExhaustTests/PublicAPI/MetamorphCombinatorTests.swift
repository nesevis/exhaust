import ExhaustCore
import Testing
@testable import Exhaust

@Suite("Metamorphic Combinator")
struct MetamorphCombinatorTests {

    // MARK: - Single Transform

    @Test("Single transform produces (original, transformed) tuple")
    func singleTransform() throws {
        let gen = #gen(.int(in: 1 ... 100)).metamorph({ $0 * 2 })
        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 30)

        while let (original, doubled) = try iterator.next() {
            #expect(1 ... 100 ~= original)
            #expect(doubled == original * 2)
        }
    }

    // MARK: - Multiple Homogeneous Transforms

    @Test("Multiple transforms of the same type produce correct tuple")
    func multipleHomogeneous() throws {
        let gen = #gen(.int(in: 0 ... 50)).metamorph(
            { $0 + 1 },
            { $0 * 10 },
            { -$0 }
        )
        var iterator = ValueInterpreter(gen, seed: 7, maxRuns: 30)

        while let (original, plusOne, timesTen, negated) = try iterator.next() {
            #expect(plusOne == original + 1)
            #expect(timesTen == original * 10)
            #expect(negated == -original)
        }
    }

    // MARK: - Heterogeneous Transforms

    @Test("Heterogeneous transforms produce typed tuple")
    func heterogeneous() throws {
        let gen = #gen(.string(length: 3 ... 10)).metamorph(
            { $0.uppercased() },
            { $0.count }
        )
        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 20)

        while let (original, uppercased, count) = try iterator.next() {
            #expect(uppercased == original.uppercased())
            #expect(count == original.count)
        }
    }

    @Test("Mixed Int and Bool transforms")
    func mixedIntBool() throws {
        let gen = #gen(.int(in: -100 ... 100)).metamorph(
            { $0 > 0 },
            { abs($0) }
        )
        var iterator = ValueInterpreter(gen, seed: 13, maxRuns: 30)

        while let (original, isPositive, absolute) = try iterator.next() {
            #expect(isPositive == (original > 0))
            #expect(absolute == abs(original))
        }
    }

    // MARK: - Determinism

    @Test("Same seed produces identical results")
    func determinism() throws {
        let gen = #gen(.int(in: 0 ... 1000)).metamorph({ $0 * 3 })

        var iter1 = ValueInterpreter(gen, seed: 99, maxRuns: 50)
        var iter2 = ValueInterpreter(gen, seed: 99, maxRuns: 50)

        while let first = try iter1.next() {
            let second = try #require(try iter2.next())
            #expect(first == second)
        }
    }

    // MARK: - Replay

    @Test("Replay from choice tree reproduces the same value")
    func replayRoundTrip() throws {
        let gen = #gen(.int(in: 1 ... 100)).metamorph(
            { $0 * 2 },
            { String($0) }
        )

        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 42)
        for _ in 0 ..< 20 {
            let (original, tree) = try #require(try iterator.next())
            let replayed = try #require(try Interpreters.replay(gen, using: tree))

            #expect(replayed.0 == original.0)
            #expect(replayed.1 == original.1)
            #expect(replayed.2 == original.2)
        }
    }

    // MARK: - Materialize Round-Trip

    @Test("Materialize round-trips through choice tree")
    func materializeRoundTrip() throws {
        let gen = #gen(.int(in: 1 ... 50)).metamorph({ -$0 })

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        for _ in 0 ..< 20 {
            let (original, tree) = try #require(try iterator.next())
            let prefix = ChoiceSequence(tree)

            switch Materializer.materialize(gen, prefix: prefix, mode: .exact, fallbackTree: tree) {
            case let .success(materialized, _, _):
                #expect(materialized.0 == original.0)
                #expect(materialized.1 == original.1)
            case .rejected, .failed:
                Issue.record("Materialize should succeed")
            }
        }
    }

    // MARK: - Bonsai Reduction

    @Test("Bonsai reduces the source and transforms follow")
    func bonsaiReduction() throws {
        let gen = #gen(.int(in: 0 ... 1000)).metamorph({ $0 * 3 })

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        var failingTree: ChoiceTree?
        for _ in 0 ..< 500 {
            guard let (value, tree) = try iterator.next() else { continue }
            if value.0 > 100 {
                failingTree = tree
                break
            }
        }

        let tree = try #require(failingTree)

        let (_, shrunk) = try #require(
            try Interpreters.bonsaiReduce(gen: gen, tree: tree, config: .fast) { $0.0 <= 100 }
        )

        #expect(shrunk.0 == 101)
        #expect(shrunk.1 == 101 * 3)
    }

    // MARK: - Composition with Other Combinators

    @Test("metamorph composes with array")
    func composesWithArray() throws {
        let gen = #gen(.int(in: 1 ... 10))
            .metamorph({ $0 * 2 })
            .array(length: 3)

        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 10)
        while let array = try iterator.next() {
            #expect(array.count == 3)
            for (original, doubled) in array {
                #expect(doubled == original * 2)
            }
        }
    }

    @Test("metamorph composes with filter")
    func composesWithFilter() throws {
        let gen = #gen(.int(in: 1 ... 100))
            .metamorph({ $0 % 2 == 0 })
            .filter { $0.0 > 50 }

        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 50)
        while let (original, isEven) = try iterator.next() {
            #expect(original > 50)
            #expect(isEven == (original % 2 == 0))
        }
    }
}
