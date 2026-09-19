import Testing
@testable import ExhaustCore

@Suite("Donor span bounds")
struct DonorSpanBoundsTests {
    @Test("A full-tree upgrade that flattens longer than the stored sequence registers no donor span past the sequence's end")
    func upgradeKeepsDonorSpansInsideTheStoredSequence() throws {
        let gen = Gen.arrayOf(
            Gen.pick(choices: [(1, Gen.choose(in: UInt64(0) ... 9)), (1, Gen.choose(in: UInt64(100) ... 109))]),
            within: 1 ... 8,
            scaling: .constant
        )
        // A short entry, as a prune hook would store it, and a longer tree of the same shape, as the exact re-materialisation of the unpruned original would produce.
        let (shortSequence, shortTree) = try materialized(gen, minimumValues: 1, maximumValues: 2)
        let (longSequence, longTree) = try materialized(gen, minimumValues: 6, maximumValues: 8)
        #expect(longSequence.count > shortSequence.count)
        var experiments = FuzzExperiments()
        experiments.pairMutation = true
        let corpus = FuzzCorpus(edgeCount: 4, experiments: experiments)
        let admission = corpus.offer(sequence: shortSequence, tree: shortTree, hits: [(edge: 1, hitCount: 1)], convergence: 1.0, generation: 0, phase: .sampling)
        #expect(admission == .admitted(index: 0, tier: .mutable))
        corpus.upgradeToFullTree(at: 0, fullTree: longTree)
        #expect(corpus.donorSpansByFingerprint.isEmpty == false, "The upgrade registered no donor spans")
        for (_, spans) in corpus.donorSpansByFingerprint {
            for span in spans {
                #expect(span.range.upperBound < shortSequence.count, "donor span \(span.range) lies past the stored sequence of \(shortSequence.count) entries")
            }
        }
    }
}

// MARK: - Helpers

private func materialized(_ gen: Generator<[UInt64]>, minimumValues: Int, maximumValues: Int) throws -> (ChoiceSequence, ChoiceTree) {
    for seed in UInt64(1) ... 400 {
        var interpreter = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: 1)
        let (value, tree) = try #require(try interpreter.next())
        if (minimumValues ... maximumValues).contains(value.count) {
            return (ChoiceSequence.flatten(tree), tree)
        }
    }
    throw DonorFixtureError.noSuitableParent
}

private enum DonorFixtureError: Error {
    case noSuitableParent
}
