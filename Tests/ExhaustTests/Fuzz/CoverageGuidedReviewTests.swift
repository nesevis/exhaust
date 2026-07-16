import ExhaustCore
import ExhaustTestSupport
import Testing
@testable import Exhaust

@Suite("Coverage-guided review regressions")
struct CoverageGuidedReviewTests {
    @Test("A reduced form remains one cluster across distinct symptoms")
    func reducedFormClustersDistinctSymptomsTogether() {
        let inventory = FaultInventory()
        let sequence: ChoiceSequence = [.just]

        _ = inventory.recordReduced(
            reducedSequence: sequence,
            reducedKey: "shared-reduced-key",
            renderDescription: { "first" },
            signature: nil,
            symptom: FailureSymptom(kind: "FirstFailure"),
            phase: .sampling,
            timestampNanoseconds: 1,
            attemptIndex: 1
        )
        _ = inventory.recordReduced(
            reducedSequence: sequence,
            reducedKey: "shared-reduced-key",
            renderDescription: { "second" },
            signature: nil,
            symptom: FailureSymptom(kind: "SecondFailure"),
            phase: .mutation,
            timestampNanoseconds: 2,
            attemptIndex: 2
        )

        let clusters = inventory.snapshot()
        #expect(clusters.count == 1)
        #expect(clusters.first?.symptoms == [
            FailureSymptom(kind: "FirstFailure"),
            FailureSymptom(kind: "SecondFailure"),
        ])
    }

    @Test("A pruned corpus entry is attributed with its own coverage")
    func prunedCorpusEntryUsesPrunedCoverage() throws {
        let generator = Gen.choose(in: 0 ... 1 as ClosedRange<Int>)
        let (zeroTree, seedProducingOne) = try treesAndSeed(for: generator)
        let hooks = FuzzHooks<Int>(
            prune: { _, _ in
                (value: 0, tree: zeroTree)
            },
            reduceStrategy: { tree, value, _ in
                FuzzReductionResult(
                    sequence: ChoiceSequence.flatten(tree),
                    tree: tree,
                    value: value,
                    propertyInvocations: 0
                )
            }
        )
        let runner = FuzzRunner(
            gen: generator,
            property: { _ in .fail(.returnedFalse) },
            source: SyntheticCoverageSource<Int>(edgeCount: 2, edges: { [$0] }),
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: seedProducingOne,
                skipScreening: true,
                attemptLimit: 1
            ),
            hooks: hooks
        )

        _ = runner.run()

        let entry = try #require(runner.corpus.entries.first)
        let materialized = Materializer.materializeAny(
            generator.erase(),
            prefix: entry.sequence,
            mode: .exact
        )
        guard case let .success(value, _, _) = materialized else {
            Issue.record("Expected the stored sequence to materialize exactly")
            return
        }
        #expect(value as? Int == 0)
        #expect(entry.signature.contains(0))
        #expect(entry.signature.contains(1) == false)
    }

    @Test("A passing prune re-evaluation does not erase the original failure")
    func passingPruneReevaluationPreservesOriginalFailure() throws {
        let generator = Gen.choose(in: 0 ... 1 as ClosedRange<Int>)
        let (zeroTree, seedProducingOne) = try treesAndSeed(for: generator)
        let hooks = FuzzHooks<Int>(
            prune: { _, _ in
                (value: 0, tree: zeroTree)
            },
            reduceStrategy: { tree, value, _ in
                FuzzReductionResult(
                    sequence: ChoiceSequence.flatten(tree),
                    tree: tree,
                    value: value,
                    propertyInvocations: 0
                )
            }
        )
        let runner = FuzzRunner(
            gen: generator,
            property: { value in
                value == 1 ? .fail(.returnedFalse) : .pass
            },
            source: SyntheticCoverageSource<Int>(edgeCount: 2, edges: { [$0] }),
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: seedProducingOne,
                skipScreening: true,
                attemptLimit: 1
            ),
            hooks: hooks
        )

        let result = runner.run()

        #expect(result.counts.totalAttempts == 1)
        #expect(result.counts.evaluatedSearchCases == 1)
        #expect(result.counts.pruneInvocations == 1)
        #expect(result.counts.classificationInvocations == 1)
        #expect(result.counts.totalPropertyInvocations == result.counts.evaluatedSearchCases
            + result.counts.pruneInvocations
            + result.counts.reductionInvocations
            + result.counts.normalizationInvocations
            + result.counts.classificationInvocations
            + result.counts.recoveryInvocations)
        #expect(result.clusters.map(\.reducedDescription) == ["1"])
        #expect(result.clusters.first?.symptoms == [.returnedFalse])
        let entry = try #require(runner.corpus.entries.first)
        #expect(entry.propertyFailed == false)
        #expect(entry.signature.contains(0))
        #expect(entry.signature.contains(1) == false)
    }
}

private func treesAndSeed(
    for generator: Generator<Int>
) throws -> (zeroTree: ChoiceTree, seedProducingOne: UInt64) {
    var zeroTree: ChoiceTree?
    var seedProducingOne: UInt64?

    for seed in UInt64(0) ..< 100 {
        var interpreter = ValueAndChoiceTreeInterpreter(
            generator,
            materializePicks: false,
            seed: seed,
            maxRuns: 1
        )
        guard let (value, tree) = try interpreter.next() else {
            continue
        }
        switch value {
            case 0 where zeroTree == nil:
                zeroTree = tree
            case 1 where seedProducingOne == nil:
                seedProducingOne = seed
            default:
                break
        }
        if zeroTree != nil, seedProducingOne != nil {
            break
        }
    }

    return try (
        zeroTree: #require(zeroTree),
        seedProducingOne: #require(seedProducingOne)
    )
}
