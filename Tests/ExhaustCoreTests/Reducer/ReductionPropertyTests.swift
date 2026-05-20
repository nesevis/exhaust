import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Reduction Properties")
struct ReductionPropertyTests {
    let reducerConfig = Interpreters.ReducerConfiguration(maxStalls: 2)

    // MARK: - Monotonicity

    @Test("Reduced integer array is shortlex-smaller than original")
    func monotonicityIntArray() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 1 ... 5)
        let (value, tree) = try generate(gen, seed: 99)

        let property: ([UInt64]) -> Bool = { $0.reduce(0, +) < 50 }
        guard property(value) == false else { return }

        let (reduced, _) = try #require(
            try Interpreters.choiceGraphReduce(
                gen: gen,
                tree: tree,
                output: value,
                config: reducerConfig,
                property: property
            )
        )

        let original = ChoiceSequence.flatten(tree)
        #expect(reduced.shortLexPrecedes(original) || reduced == original)
    }

    @Test("Reduced pick-based value is shortlex-smaller than original")
    func monotonicityPick() throws {
        let gen = Gen.pick(choices: [
            (weight: UInt64(1), generator: Gen.choose(in: UInt64(0) ... 50)),
            (weight: UInt64(1), generator: Gen.choose(in: UInt64(51) ... 100)),
            (weight: UInt64(1), generator: Gen.choose(in: UInt64(101) ... 200)),
        ])
        let (value, tree) = try generate(gen, seed: 77)

        let property: (UInt64) -> Bool = { $0 < 30 }
        guard property(value) == false else { return }

        let (reduced, _) = try #require(
            try Interpreters.choiceGraphReduce(
                gen: gen,
                tree: tree,
                output: value,
                config: reducerConfig,
                property: property
            )
        )

        let original = ChoiceSequence.flatten(tree)
        #expect(reduced.shortLexPrecedes(original) || reduced == original)
    }

    @Test("Reduced nested array is shortlex-smaller than original", .tags(.slow))
    func monotonicityNestedArray() throws {
        let gen = Gen.arrayOf(
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 20), within: 0 ... 3),
            within: 1 ... 4
        )

        for seed: UInt64 in [42, 99, 137, 271, 500] {
            let (value, tree) = try generate(gen, seed: seed)

            let property: ([[UInt64]]) -> Bool = { $0.flatMap(\.self).count < 3 }
            guard property(value) == false else { continue }

            let (reduced, _) = try #require(
                try Interpreters.choiceGraphReduce(
                    gen: gen,
                    tree: tree,
                    output: value,
                    config: reducerConfig,
                    property: property
                )
            )

            let original = ChoiceSequence.flatten(tree)
            #expect(
                reduced.shortLexPrecedes(original) || reduced == original,
                "Seed \(seed): reduced sequence must not grow"
            )
        }
    }

    // MARK: - Idempotence

    @Test("Reducing an already-reduced value produces the same sequence")
    func idempotenceIntArray() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 0 ... 5)
        let (value, tree) = try generate(gen, seed: 42)

        let property: ([UInt64]) -> Bool = { $0.reduce(0, +) < 50 }
        guard property(value) == false else { return }

        let (firstSequence, firstOutput) = try #require(
            try Interpreters.choiceGraphReduce(
                gen: gen,
                tree: tree,
                output: value,
                config: reducerConfig,
                property: property
            )
        )

        guard case let .success(_, secondTree, _) = Materializer.materialize(
            gen,
            prefix: firstSequence,
            mode: .exact,
            fallbackTree: tree
        ) else {
            Issue.record("Failed to materialize reduced sequence")
            return
        }

        let secondResult = try Interpreters.choiceGraphReduce(
            gen: gen,
            tree: secondTree,
            output: firstOutput,
            config: reducerConfig,
            property: property
        )

        if let (secondSequence, _) = secondResult {
            #expect(secondSequence == firstSequence)
        }
    }

    @Test("Reducing a minimal single value is a no-op")
    func idempotenceMinimalValue() throws {
        let gen = Gen.choose(in: UInt64(0) ... 100)
        let tree = try #require(try Interpreters.reflect(gen, with: UInt64(0)))

        let property: (UInt64) -> Bool = { $0 > 0 }

        let result = try Interpreters.choiceGraphReduce(
            gen: gen,
            tree: tree,
            output: UInt64(0),
            config: reducerConfig,
            property: property
        )

        let originalSequence = ChoiceSequence.flatten(tree)
        if let (reduced, _) = result {
            #expect(reduced == originalSequence)
        }
    }
}

private extension Tag {
    @Tag static var slow: Self
}
