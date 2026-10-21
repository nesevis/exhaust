import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Sequence length bounds in mutation targets")
struct SequenceLengthBoundTests {
    @Test("Deletion and duplication obey both length bounds", arguments: [
        (2, UInt64(2) ... 5),
        (3, UInt64(2) ... 5),
        (3, UInt64(1) ... 3),
        (2, UInt64(1) ... 5),
        (2, UInt64(2) ... 2),
    ])
    func lengthBounds(count: Int, range: ClosedRange<UInt64>) {
        let tree = ChoiceTree.group([
            .sequence(elements: (0 ..< count).map { .uint64(UInt64($0), in: 0 ... 100) },
                      metadata: .init(validRange: range, isRangeExplicit: true)),
        ])
        let targets = MutationTargets(tree: tree)
        #expect(targets.deletableSequenceNodeIDs.count == (UInt64(count) > range.lowerBound ? 1 : 0))
        #expect(targets.duplicableSequenceNodeIDs.count == (UInt64(count) < range.upperBound ? 1 : 0))
    }
}

// MARK: - Crossover Self-Donation Tests

@Suite("Crossover excludes self-donation")
struct CrossoverSelfDonationTests {
    @Test("Crossover needs a distinct donor with the same fingerprint", arguments: [false, true])
    func twoEntriesHaveCrossoverDonor(hasDonor: Bool) throws {
        let corpus = FuzzCorpus(edgeCount: 4, experiments: targetingExperiments(graph: true, pair: true))
        let firstIndex = try admitPickPair(into: corpus, fingerprint: 42, values: (100, 200), edge: 0)
        if hasDonor {
            _ = try admitPickPair(into: corpus, fingerprint: 42, values: (300, 400), edge: 1)
        }
        let targets = try #require(corpus.mutationTargets(forParentAt: firstIndex))
        #expect(targets.hasCrossoverDonor(corpus: corpus, parentIndex: firstIndex) == hasDonor)
    }
}
