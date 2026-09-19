import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing

@Suite("Reducer: zip under a lazy bind")
struct LazyZipExactDecodeTests {
    /// A `.lazy` bind's unit inner emits a `.just` entry that the cursor never consumes. The exact-mode zip parser used to require the cursor to sit on the zip open, so a zip directly under `.lazy` never parsed from the prefix and the fallback scoping fenced the second child's value out. Every value probe inside the bind was then rejected at materialization and the pair never reduced.
    @Test("Values inside a zip bound by .lazy reduce without materialization rejections")
    func valuesInsideLazyZipReduce() throws {
        let pairGen: ReflectiveGenerator<(Int, Int)?> = .oneOf(
            weighted: (1, .just((Int, Int)?.none)),
            (3, .lazy {
                Gen.zip(Gen.choose(in: -1000 ... 1000), Gen.choose(in: -1000 ... 1000))
                    .map { Optional(($0, $1)) }
                    .wrapped(isReflective: true)
            })
        )

        var fixture: (value: (Int, Int)?, tree: ChoiceTree)?
        for iteration in 0 ..< 200 {
            let candidate = try generate(pairGen.gen, iteration: iteration)
            guard let pair = candidate.value, pair != (0, 0) else {
                continue
            }
            fixture = candidate
            break
        }
        let generated = try #require(fixture, "No iteration below 200 drew a pair other than nil or (0, 0)")

        let result = try Interpreters.choiceGraphReduceCollectingStats(
            gen: pairGen.gen,
            tree: generated.tree,
            output: generated.value,
            config: reducerConfig,
            property: { $0 == nil }
        )

        let reduced = try #require(result.outcome.counterexample)
        let pair = try #require(reduced.1)
        #expect(pair == (0, 0))
        #expect(result.stats.reductionProbesRejectedDuringMaterialization == 0)
    }
}

private let reducerConfig = Interpreters.ReducerConfiguration(maxStalls: 2)
