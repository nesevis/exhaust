import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Reducer: sibling value reordering")
struct ReducerReorderTests {
    @Test("Reordering sorts without changing values and replays its result", arguments: [
        [UInt64(3), 1, 2],
        [1, 2, 3],
        [4, 1, 3, 2],
        [5, 3, 1, 4, 2],
    ])
    func sortsAndReplays(values: [UInt64]) throws {
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 1000), exactly: UInt64(values.count))
        let tree = try #require(try Interpreters.reflect(generator, with: values))
        let (sequence, output) = try #require(Interpreters.choiceGraphReduce(
            gen: generator, tree: tree, output: values, config: reorderConfiguration, property: { _ in false }
        ).counterexample)

        #expect(output == values.sorted())
        #expect(ChoiceSequence.validate(sequence))
        guard case let .success(replayed, _, _) = Materializer.materialize(
            generator, context: .init(prefix: sequence, mode: .exact, fallbackTree: tree)
        ) else {
            Issue.record("Reordered history failed exact replay")
            return
        }
        #expect(replayed == output)
    }

    @Test("Reordering preserves a failure that requires an unsorted array")
    func refusesPassingOrder() throws {
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 3)
        let original: [UInt64] = [3, 1, 2]
        let reduced = try reduceFromReflection(generator, startingAt: original, config: reorderConfiguration) {
            $0 == $0.sorted()
        }
        #expect(reduced != reduced.sorted())
        #expect(reduced.sorted() == original.sorted())
    }
}

private let reorderConfiguration = Interpreters.ReducerConfiguration(maxStalls: 2, enabledEncoders: [.numericReorder])
