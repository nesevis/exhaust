//
//  MetamorphUniqueRegressionTests.swift
//  Exhaust
//
//  Pins the metamorphic-copy dedup exemption. Metamorphic copies re-generate the inner from a reset PRNG; with a unique inside, the original's accepted sequence was already in the shared seen-set, so dedup forced every copy to a fresh draw — a pair whose halves differed under the identity transform, and a tree that no longer determined the value. Copies now replay against a snapshot of the dedup state the original saw, and their insertions are discarded. Found by the self-fuzzing harness (ExhaustDocs/coverage-guided-self-fuzzing.md).
//

import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Metamorph over unique")
struct MetamorphUniqueRegressionTests {
    @Test("Identity metamorph over unique produces equal halves", arguments: [UInt64(0), 1, 7, 42])
    func identityCopiesMatchOriginal(seed: UInt64) throws {
        let recipe = GenRecipe.combinator(.metamorphed(
            .combinator(.unique(.leaf(.int(-1 ... 0)))),
            .identity
        ))
        let gen = buildGenerator(from: recipe)
        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: 2)
        var checked = 0
        while let (value, tree) = try iterator.next() {
            let pair = try #require(value as? [Any])
            #expect(anyEquals(pair[0], pair[1]), "Identity metamorph produced unequal halves \(pair), seed \(seed)")

            let sequence = ChoiceSequence.flatten(tree)
            switch Materializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: tree) {
                case let .success(materialized, _, _):
                    #expect(anyEquals(materialized, value), "Exact replay produced \(materialized), not \(value), seed \(seed)")
                case .rejected, .failed:
                    Issue.record("Exact materialization rejected the tree's own flattening, seed \(seed)")
                    return
            }
            checked += 1
        }
        #expect(checked > 0)
    }

    @Test("The original inside a metamorph still dedupes across runs")
    func originalStillDedupes() throws {
        // unique over a two-value domain: across runs, the originals must all be distinct until the domain is exhausted — the copy exemption must not leak into the original's own generation.
        let recipe = GenRecipe.combinator(.metamorphed(
            .combinator(.unique(.leaf(.int(-1 ... 0)))),
            .identity
        ))
        let gen = buildGenerator(from: recipe)
        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 3, maxRuns: 2)
        var originals: [Int] = []
        while let (value, _) = try iterator.next() {
            let pair = try #require(value as? [Any])
            try originals.append(#require(pair[0] as? Int))
        }
        #expect(Set(originals).count == originals.count, "Originals repeated across runs: \(originals)")
    }
}
