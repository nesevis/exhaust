import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing
@testable import Exhaust

@Suite("#explore(time:) crash resume")
struct ExploreTimeResumeTests {
    @Test("A crashed predecessor restores: corpus and inventory carry over, phases skip to the mutation phase, the trap reports, and completion removes the log")
    func resumeEndToEnd() throws {
        let directory = scratchDirectory()
        let store = FuzzProgressStore(directory: directory)
        defer {
            store.removeAll()
        }
        let gen = Gen.choose(in: 0 ... 100 as ClosedRange<Int>)

        // Build the predecessor's snapshot from really-generated sequences so `.exact` re-materialisation succeeds against the same generator.
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 1, maxRuns: UInt64.max)
        let helperCorpus = FuzzCorpus(edgeCount: 32)
        var sequences: [ChoiceSequence] = []
        while sequences.count < 5, let (value, tree) = try interpreter.next() {
            let sequence = ChoiceSequence.flatten(tree)
            let admission = helperCorpus.offer(
                sequence: sequence,
                tree: tree,
                hits: [(edge: abs(value) % 10, hitCount: 1)],
                convergence: 1.0,
                generation: 0,
                phase: .sampling
            )
            if case .admitted = admission {
                sequences.append(sequence)
            }
        }
        let entryRecords = helperCorpus.entries.map(FuzzProgressDocument.CorpusEntryRecord.init(entry:))

        let clusterRecord = FuzzProgressDocument.ClusterRecord(
            cluster: FaultCluster(
                restoredID: 0,
                reducedSequence: sequences[0],
                reducedDescription: "planted-restored-cluster",
                reducedKey: "planted-restored-cluster",
                signatures: [],
                symptoms: [.returnedFalse],
                instanceCount: 3,
                reducedCount: 1,
                firstSeenNanoseconds: 1_000_000,
                lastSeenNanoseconds: 2_000_000,
                firstSeenAttempt: 1,
                unnormalizedMemberCount: 0,
                discoveringPhase: .mutation
            ),
            epochNanoseconds: 0
        )
        let document = FuzzProgressDocument(
            metadata: FuzzProgressDocument.Metadata(
                seed: 9,
                budgetNanoseconds: 60_000_000_000,
                consumedNanoseconds: 55_000_000_000,
                lastCheckpointEpochSeconds: Date().timeIntervalSince1970,
                pcTableHash: 0,
                edgeCount: 32
            ),
            clusters: [clusterRecord],
            snapshot: entryRecords
        )
        try store.write(document)

        // The predecessor died evaluating a mutation of the first snapshot entry.
        let parentHash = ZobristHash.hash(of: sequences[0])
        var breadcrumbBytes = Data()
        withUnsafeBytes(of: UInt64(0xABCD).littleEndian) { breadcrumbBytes.append(contentsOf: $0) }
        withUnsafeBytes(of: parentHash.littleEndian) { breadcrumbBytes.append(contentsOf: $0) }
        try breadcrumbBytes.write(to: store.breadcrumbFileURL)

        let context = FuzzPersistenceContext(store: store, resumeEnabled: true)
        #expect(context.resumeDocument != nil)
        #expect(context.survivor?.candidateHash == 0xABCD)
        #expect(context.survivorParentSequence() == sequences[0])

        // The crash finding is never silent.
        withKnownIssue {
            __ExhaustRuntime.reportFuzzResumeFindings(
                context: context,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
        }

        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: gen,
            time: .seconds(60),
            settings: [.replay(9), .suppress(.all)],
            source: resumeSource(),
            configure: { configuration in
                configuration.attemptLimit = 300
            },
            persistence: context,
            property: { _ in .pass }
        )

        // Restored state: the cluster is present verbatim, the corpus carries the snapshot, and both inherited phases were skipped.
        #expect(report.clusters.contains { $0.reducedDescription == "planted-restored-cluster" && $0.instanceCount == 3 })
        #expect(report.corpusEntryCount >= sequences.count)
        #expect(report.screeningAttempts == 0)
        #expect(report.samplingAttempts == 0)
        #expect(report.mutationAttempts > 0)
        #expect(report.termination == .attemptLimitReached)

        // Normal completion removes the recovery state — a surviving log is the crash signal.
        #expect(FileManager.default.fileExists(atPath: store.progressFileURL.path) == false)
    }

    @Test("Resume opt-out ignores predecessor state")
    func resumeOptOut() throws {
        let directory = scratchDirectory()
        let store = FuzzProgressStore(directory: directory)
        defer {
            store.removeAll()
        }
        try store.write(FuzzProgressDocument(
            metadata: FuzzProgressDocument.Metadata(
                seed: 1,
                budgetNanoseconds: 1,
                consumedNanoseconds: 0,
                lastCheckpointEpochSeconds: Date().timeIntervalSince1970,
                pcTableHash: 0,
                edgeCount: 8
            ),
            clusters: [],
            snapshot: []
        ))
        let context = FuzzPersistenceContext(store: store, resumeEnabled: false)
        #expect(context.resumeDocument == nil)
        #expect(context.survivor == nil)
    }
}

// MARK: - Helpers

private func scratchDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("exhaust-resume-tests")
        .appendingPathComponent(UUID().uuidString)
}

private func resumeSource() -> SyntheticCoverageSource<Int> {
    SyntheticCoverageSource<Int>(edgeCount: 32, edges: { value in
        var edges = [abs(value) % 10]
        if value > 50 {
            edges.append(10)
        }
        return edges
    })
}
