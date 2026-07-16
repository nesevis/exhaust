import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Bound-array shortlex regressions", .serialized)
struct BoundArrayShortlexRegressionTests {
    @Test("MetaFuzz shortlex oracle excludes final numeric reordering")
    func metaFuzzOracleExcludesNumericReordering() throws {
        let fuzzCase = MetaFuzzCase(
            recipe: .combinator(.boundArray(
                element: .combinator(.boundRange(.leaf(.int(-89 ... -63)))),
                maxLength: 3
            )),
            valueSeed: 4,
            perturbationSeed: 0
        )

        try MetaFuzz.check(fuzzCase)
    }

    @Test(
        arguments: [
            (range: -89 ... -63, maxLength: UInt64(3)),
            (range: -89 ... -63, maxLength: UInt64(4)),
            (range: -89 ... -63, maxLength: UInt64(5)),
            (range: -96 ... -46, maxLength: UInt64(3)),
        ]
    )
    func reductionOrdering(
        range: ClosedRange<Int>,
        maxLength: UInt64
    ) throws {
        let recipe: GenRecipe = .combinator(.boundArray(
            element: .combinator(.boundRange(.leaf(.int(range)))),
            maxLength: maxLength
        ))
        let gen = buildGenerator(from: recipe)
        let property = failingProperty(for: recipe.outputType)
        var iterator = ValueAndChoiceTreeInterpreter(
            gen,
            seed: 4,
            maxRuns: MetaFuzz.valuesPerCase
        )

        while let (value, tree) = try iterator.next() {
            guard property(value) == false else {
                continue
            }

            let original = ChoiceSequence.flatten(tree)
            let reduction = try Interpreters.choiceGraphReduceCollectingStats(
                gen: gen,
                tree: tree,
                output: value,
                config: .init(
                    maxStalls: 2,
                    wallClockDeadlineNanoseconds: FuzzTunables.reductionDeadlineNanoseconds,
                    enabledEncoders: Set(EncoderName.allCases).subtracting([
                        .numericReorder,
                    ])
                ),
                property: property
            )

            guard case let .reduced(reduced, _, shrunk) = reduction.outcome else {
                Issue.record("Seed 4 did not produce a reduction")
                return
            }

            #expect(property(shrunk) == false)
            #expect(reduced.shortLexPrecedes(original))
            #expect(reduction.stats.encoderProbesAccepted[.numericReorder, default: 0] == 0)
            return
        }

        Issue.record("Seed 4 produced no failing value")
    }
}
