import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Enabled encoder filter")
struct EnabledEncoderFilterTests {
    @Test("Deletion-only pass shortens the array but does not simplify values")
    func deletionOnlyShortensButDoesNotSimplify() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(50) ... 100), within: 0 ... 10)
        let value: [UInt64] = [77, 88, 99, 66, 55]
        let tree = try #require(try Interpreters.reflect(gen, with: value))

        let config = Interpreters.ReducerConfiguration(
            maxStalls: 2,
            enabledEncoders: [.deletion]
        )
        let property: ([UInt64]) -> Bool = { $0.count < 3 }

        let result = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: config, property: property)
        )

        #expect(result.1.count >= 3, "Property requires count >= 3 to fail")
        #expect(result.1.count < 5, "Deletion should have removed at least one element")
        #expect(result.1.allSatisfy { $0 >= 50 }, "Values should remain in the original range (no value search)")
    }

    @Test("Value-search-only pass simplifies values but does not shorten the array")
    func valueSearchOnlySimplifiesButDoesNotShorten() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 0 ... 10)
        let value: [UInt64] = [80, 60, 70, 90]
        let tree = try #require(try Interpreters.reflect(gen, with: value))

        let config = Interpreters.ReducerConfiguration(
            maxStalls: 2,
            enabledEncoders: [.valueSearch]
        )
        let property: ([UInt64]) -> Bool = { $0.count != 4 || $0.allSatisfy { $0 == 0 } }

        let result = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: config, property: property)
        )

        #expect(result.1.count == 4, "Array length should be unchanged (no deletion)")
        #expect(result.1.reduce(0, +) < value.reduce(0, +), "Values should be reduced toward zero")
    }

    @Test("Nil enabledEncoders applies both structural and value reduction")
    func nilMeansAllEncoders() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 0 ... 10)
        let value: [UInt64] = [80, 60, 70, 90, 50]
        let tree = try #require(try Interpreters.reflect(gen, with: value))

        let config = Interpreters.ReducerConfiguration(maxStalls: 2)
        let property: ([UInt64]) -> Bool = { $0.count < 3 || $0.allSatisfy { $0 == 0 } }

        let result = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: config, property: property)
        )

        #expect(result.1.count < 5, "Deletion should shorten the array")
        #expect(result.1.count >= 3, "Property requires count >= 3 to fail")
        #expect(result.1.contains { $0 > 0 }, "At least one value must be non-zero for property to fail")
        #expect(result.1.filter { $0 > 0 }.allSatisfy { $0 <= 2 }, "Non-zero values should be reduced close to zero")
    }

    @Test("Empty enabledEncoders set produces no improvement")
    func emptySetDisablesAll() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(10) ... 100), within: 0 ... 10)
        let value: [UInt64] = [33, 46, 56, 80]
        let tree = try #require(try Interpreters.reflect(gen, with: value))

        let config = Interpreters.ReducerConfiguration(
            maxStalls: 2,
            enabledEncoders: []
        )
        let property: ([UInt64]) -> Bool = { $0.count < 2 }

        let result = try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: config, property: property)

        if let result {
            #expect(result.1 == value, "No encoders enabled means the result should be unchanged")
        }
        // nil result is also acceptable — it means no improvement was found
    }

    @Test("Two-pass staging: structural then value reaches the same result as all-at-once")
    func twoPassStagingMatchesFullReduction() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 0 ... 10)
        let value: [UInt64] = [80, 60, 70, 90, 50]
        let tree = try #require(try Interpreters.reflect(gen, with: value))

        let property: ([UInt64]) -> Bool = { $0.count < 3 || $0.allSatisfy { $0 == 0 } }

        let structural: Set<EncoderName> = [.deletion, .migration, .substitution]
        let cosmetic = Set(EncoderName.allCases).subtracting(structural)

        // Pass 1: structural
        let afterStructural = try #require(
            try Interpreters.choiceGraphReduce(
                gen: gen, tree: tree,
                config: .init(maxStalls: 2, enabledEncoders: structural),
                property: property
            )
        )

        // Rematerialize tree for pass 2
        guard case let .success(_, pass1Tree, _) = Materializer.materialize(
            gen, prefix: afterStructural.0, mode: .exact, fallbackTree: tree, materializePicks: true
        ) else {
            Issue.record("Failed to rematerialize after structural pass")
            return
        }

        // Pass 2: cosmetic
        let afterCosmetic = try Interpreters.choiceGraphReduce(
            gen: gen, tree: pass1Tree,
            config: .init(maxStalls: 2, enabledEncoders: cosmetic),
            property: property
        )
        let twoPassResult = afterCosmetic?.1 ?? afterStructural.1

        // Full reduction in one pass
        let fullResult = try #require(
            try Interpreters.choiceGraphReduce(
                gen: gen, tree: tree,
                config: .init(maxStalls: 2),
                property: property
            )
        )

        #expect(twoPassResult.count == fullResult.1.count, "Two-pass should reach the same array length")
        #expect(twoPassResult == fullResult.1, "Two-pass should reach the same final result")
    }
}
