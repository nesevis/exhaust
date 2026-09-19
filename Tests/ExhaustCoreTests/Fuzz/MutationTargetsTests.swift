import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Sequence length bounds in mutation targets")
struct SequenceLengthBoundTests {
    @Test("Deletion excludes a sequence at its lower bound")
    func deletionRespectsLowerBound() {
        let tree = ChoiceTree.group([
            .sequence(
                elements: [
                    .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                    .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                ],
                metadata: .init(validRange: 2 ... 5, isRangeExplicit: true)
            ),
        ])
        let targets = MutationTargets(tree: tree)
        #expect(targets.deletableSequenceNodeIDs.isEmpty)
    }

    @Test("Deletion includes a sequence above its lower bound")
    func deletionAllowsAboveLowerBound() {
        let tree = ChoiceTree.group([
            .sequence(
                elements: [
                    .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                    .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                    .choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                ],
                metadata: .init(validRange: 2 ... 5, isRangeExplicit: true)
            ),
        ])
        let targets = MutationTargets(tree: tree)
        #expect(targets.deletableSequenceNodeIDs.isEmpty == false)
    }

    @Test("Duplication excludes a sequence at its upper bound")
    func duplicationRespectsUpperBound() {
        let tree = ChoiceTree.group([
            .sequence(
                elements: [
                    .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                    .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                    .choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                ],
                metadata: .init(validRange: 1 ... 3, isRangeExplicit: true)
            ),
        ])
        let targets = MutationTargets(tree: tree)
        #expect(targets.duplicableSequenceNodeIDs.isEmpty)
    }

    @Test("Duplication includes a sequence below its upper bound")
    func duplicationAllowsBelowUpperBound() {
        let tree = ChoiceTree.group([
            .sequence(
                elements: [
                    .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                    .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                ],
                metadata: .init(validRange: 1 ... 5, isRangeExplicit: true)
            ),
        ])
        let targets = MutationTargets(tree: tree)
        #expect(targets.duplicableSequenceNodeIDs.isEmpty == false)
    }

    @Test("Fixed-length sequence excludes both deletion and duplication")
    func fixedLengthExcludesBoth() {
        let tree = ChoiceTree.group([
            .sequence(
                elements: [
                    .choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                    .choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 100)),
                ],
                metadata: .init(validRange: 2 ... 2, isRangeExplicit: true)
            ),
        ])
        let targets = MutationTargets(tree: tree)
        #expect(targets.deletableSequenceNodeIDs.isEmpty)
        #expect(targets.duplicableSequenceNodeIDs.isEmpty)
    }
}

// MARK: - Crossover Self-Donation Tests

@Suite("Crossover excludes self-donation")
struct CrossoverSelfDonationTests {
    @Test("Single-entry corpus reports no crossover donor")
    func singleEntryHasNoCrossoverDonor() throws {
        let corpus = FuzzCorpus(edgeCount: 4, experiments: targetingExperiments(graph: true, pair: true))
        let parentIndex = try admitPickPair(into: corpus, fingerprint: 42, values: (100, 200), edge: 0)
        let targets = corpus.mutationTargets(forParentAt: parentIndex)!
        #expect(targets.hasCrossoverDonor(corpus: corpus, parentIndex: parentIndex) == false)
    }

    @Test("Two-entry corpus with matching fingerprints reports a crossover donor")
    func twoEntriesHaveCrossoverDonor() throws {
        let corpus = FuzzCorpus(edgeCount: 4, experiments: targetingExperiments(graph: true, pair: true))
        let firstIndex = try admitPickPair(into: corpus, fingerprint: 42, values: (100, 200), edge: 0)
        _ = try admitPickPair(into: corpus, fingerprint: 42, values: (300, 400), edge: 1)
        let targets = corpus.mutationTargets(forParentAt: firstIndex)!
        #expect(targets.hasCrossoverDonor(corpus: corpus, parentIndex: firstIndex))
    }
}
