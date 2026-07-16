import ExhaustTestSupport
import Foundation
import Testing
@testable import ExhaustCore

@Suite("Coverage-guided recovery review regressions")
struct CoverageGuidedRecoveryReviewTests {
    #if canImport(Darwin) || canImport(Glibc)
        @Test("Resume reattribution clears the predecessor breadcrumb before evaluating")
        func resumeReattributionClearsPredecessorBreadcrumbBeforeProperty() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("exhaust-coverage-guided-recovery-review")
                .appendingPathComponent(UUID().uuidString)
            let store = FuzzProgressStore(directory: directory)
            defer {
                store.removeAll()
            }

            let generator = Gen.choose(in: 0 ... 1 as ClosedRange<Int>)
            let (value, tree) = try generatedValueAndTree(generator)
            let corpus = FuzzCorpus(edgeCount: 1)
            _ = corpus.offer(
                sequence: ChoiceSequence.flatten(tree),
                tree: tree,
                hits: [(edge: 0, hitCount: 1)],
                convergence: 1,
                generation: 0,
                phase: .sampling
            )
            let document = FuzzProgressDocument(
                metadata: FuzzProgressDocument.Metadata(
                    seed: 1,
                    budgetNanoseconds: 60_000_000_000,
                    consumedNanoseconds: 1,
                    lastCheckpointEpochSeconds: Date().timeIntervalSince1970,
                    pcTableHash: 0,
                    edgeCount: 1
                ),
                clusters: [],
                snapshot: corpus.entries.map(FuzzProgressDocument.CorpusEntryRecord.init(entry:))
            )
            try store.write(document)
            let breadcrumb = try #require(FuzzBreadcrumb(fileURL: store.breadcrumbFileURL))
            breadcrumb.record(candidateHash: 0xAAAA, parentHash: 0xBBBB)
            let persistence = FuzzPersistenceContext(store: store, resumeEnabled: true)
            let survivorObservedByProperty = SendableBox<(candidateHash: UInt64, parentHash: UInt64)?>(nil)
            let runner = FuzzRunner(
                gen: generator,
                property: { _ in
                    survivorObservedByProperty.withValue {
                        $0 = FuzzBreadcrumb.readSurvivor(fileURL: store.breadcrumbFileURL)
                    }
                    return .pass
                },
                source: SyntheticCoverageSource<Int>(edgeCount: 2, edges: { [$0] }),
                configuration: FuzzRunnerConfiguration(
                    budgetNanoseconds: 60_000_000_000,
                    seed: 1,
                    skipScreening: true,
                    skipSampling: true,
                    attemptLimit: 0,
                    persistence: persistence
                )
            )

            _ = runner.run()

            #expect(value == 0 || value == 1)
            #expect(survivorObservedByProperty.withValue { $0 } == nil)
        }
    #endif
}

private func generatedValueAndTree(
    _ generator: Generator<Int>
) throws -> (value: Int, tree: ChoiceTree) {
    var interpreter = ValueAndChoiceTreeInterpreter(
        generator,
        materializePicks: false,
        seed: 1,
        maxRuns: 1
    )
    return try #require(try interpreter.next())
}
