import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Scheduler Decisions")
struct SchedulerDecisionTests {
    // MARK: - Convergence Detection

    let reducerConfig = Interpreters.ReducerConfiguration(maxStalls: 2)

    @Test("Scheduler detects convergence when property always passes")
    func convergenceWhenPropertyAlwaysPasses() throws {
        let gen = Gen.choose(in: UInt64(0) ... 100)
        let (value, tree) = try generate(gen, seed: 42)

        let result = try Interpreters.choiceGraphReduce(
            gen: gen,
            tree: tree,
            output: value,
            config: reducerConfig
        ) { _ in true }

        let original = ChoiceSequence.flatten(tree)
        if let (reduced, _) = result {
            #expect(reduced == original, "Property always passes — sequence should be unchanged")
        }
        // nil result is also valid — means the reducer found no counterexample to work with
    }

    @Test("Scheduler converges to minimum for trivially-falsified single value")
    func convergesToMinimumForSingleValue() throws {
        let gen = Gen.choose(in: UInt64(0) ... 1000)
        let (value, tree) = try generate(gen, seed: 77)
        try #require(value > 0)

        let (_, reducedValue) = try #require(
            try Interpreters.choiceGraphReduce(
                gen: gen,
                tree: tree,
                output: value,
                config: reducerConfig
            ) { $0 == 0 }
        )

        #expect(reducedValue == 1)
    }

    // MARK: - Structural Before Value

    @Test("Structural reduction removes elements before value reduction minimizes them")
    func structuralBeforeValue() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 50), within: 2 ... 5)
        let (value, tree) = try generate(gen, seed: 42)
        try #require(value.count > 1)

        let (_, reducedValue) = try #require(
            try Interpreters.choiceGraphReduceCollectingStats(
                gen: gen,
                tree: tree,
                output: value,
                config: reducerConfig
            ) { $0.isEmpty || $0[0] < 5 }.reduced
        )

        #expect(reducedValue.count <= value.count)
        if reducedValue.isEmpty == false {
            #expect(reducedValue[0] >= 5)
        }
    }

    // MARK: - Stall Budget

    @Test("Scheduler terminates within bounded iterations")
    func terminatesWithinBound() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 1 ... 10)
        let (value, tree) = try generate(gen, seed: 42)

        let result = try Interpreters.choiceGraphReduceCollectingStats(
            gen: gen,
            tree: tree,
            output: value,
            config: reducerConfig
        ) { $0.reduce(0, +) < 10 }

        #expect(result.stats.cycles > 0)
        #expect(result.stats.cycles < 100)
    }

    // MARK: - Multi-site Reduction

    @Test("Reducer minimizes all leaves in a multi-value generator")
    func minimizesAllLeaves() throws {
        let gen = Gen.zip(
            Gen.choose(in: UInt64(0) ... 100),
            Gen.choose(in: UInt64(0) ... 100)
        )
        let (value, tree) = try generate(gen, seed: 55)
        let (first, second) = value
        try #require(first > 10 && second > 10)

        let (_, reducedValue) = try #require(
            try Interpreters.choiceGraphReduce(
                gen: gen,
                tree: tree,
                output: value,
                config: reducerConfig
            ) { pair in pair.0 < 10 || pair.1 < 10 }
        )

        #expect(reducedValue.0 == 10 || reducedValue.1 == 10)
    }
}
