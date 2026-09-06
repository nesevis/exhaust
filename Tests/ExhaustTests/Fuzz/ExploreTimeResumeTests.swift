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

        // Build the predecessor's snapshot from really-generated sequences so `.exact` re-materialization succeeds against the same generator.
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 1, maxRuns: UInt64.max)
        let helperCorpus = FuzzCorpus(edgeCount: 32)
        var sequences: [ChoiceSequence] = []
        var values: [Int] = []
        // Six, and the snapshot holds all of them: the last is both the planted cluster's reduced form and a restored entry, so re-judging the snapshot walks straight back into the cluster the record restored.
        while sequences.count < 6, let (value, tree) = try interpreter.next() {
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
                values.append(value)
            }
        }
        let entryRecords = helperCorpus.entries.map(FuzzProgressDocument.CorpusEntryRecord.init(entry:))
        let plantedValue = values[5]

        let clusterRecord = FuzzProgressDocument.ClusterRecord(
            cluster: FaultCluster(
                restoredID: 0,
                reducedSequence: sequences[5],
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
                attemptsConsumed: 1000,
                lastCheckpointEpochSeconds: Date().timeIntervalSince1970,
                pcTableHash: 0,
                edgeCount: 32
            ),
            clusters: [clusterRecord],
            snapshot: Array(entryRecords)
        )
        try store.write(document)

        // The predecessor died evaluating a mutation of the first snapshot entry. Written through the real breadcrumb so the slot layout, checksum, and commit marker are the ones a live run produces.
        let parentHash = ZobristHash.hash(of: sequences[0])
        let predecessorBreadcrumb = try #require(FuzzBreadcrumb(fileURL: store.breadcrumbFileURL, recordsCandidateSequence: true))
        predecessorBreadcrumb.record(
            candidateHash: 0xABCD,
            parentHash: parentHash,
            kind: .search,
            sequence: sequences[0]
        )

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
            source: .injected(resumeSource()),
            configure: { configuration in
                configuration.attemptLimit = 300
            },
            persistence: context,
            // Restore re-judges every restored cluster and entry against the current build, so the planted fault has to still be a fault for the inventory to carry it over. A symptom of its own identifies the cluster without depending on how the reduced value renders.
            property: { $0 == plantedValue ? .fail(FailureSymptom(kind: "PlantedFault")) : .pass }
        )

        // Restored state: the cluster carried over, the corpus carries the snapshot, and both inherited phases were skipped.
        // Symptom and description both come from restore's own evaluation, not from the record: the predecessor wrote `returnedFalse` and "planted-restored-cluster". What pins this as the carried-over cluster rather than one this run minted is the discovery attempt index, which only the record supplies.
        let restored = try #require(report.clusters.first { $0.symptoms == ["PlantedFault"] })
        #expect(restored.firstSeenAttempt == 1)
        #expect(restored.instanceCount >= 3)
        #expect(restored.reducedDescription != "planted-restored-cluster")
        #expect(report.coverage.corpusEntryCount >= entryRecords.count)
        #expect(report.attempts.screening == 0)
        #expect(report.attempts.sampling == 0)
        #expect(report.attempts.mutation > 0)
        #expect(report.termination == .attemptLimitReached)

        // Normal completion removes the recovery state — a surviving log is the crash signal.
        #expect(FileManager.default.fileExists(atPath: store.progressFileURL.path) == false)
    }

    @Test("A PC-table-hash mismatch re-attributes corpus entries from the live source")
    func reattributionOnHashMismatch() throws {
        let directory = scratchDirectory()
        let store = FuzzProgressStore(directory: directory)
        defer {
            store.removeAll()
        }
        let gen = Gen.choose(in: 0 ... 100 as ClosedRange<Int>)

        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 1, maxRuns: UInt64.max)
        let helperCorpus = FuzzCorpus(edgeCount: 16)
        while helperCorpus.entries.count < 3, let (value, tree) = try interpreter.next() {
            let sequence = ChoiceSequence.flatten(tree)
            _ = helperCorpus.offer(
                sequence: sequence,
                tree: tree,
                hits: [(edge: abs(value) % 4, hitCount: 1)],
                convergence: 1.0,
                generation: 0,
                phase: .sampling
            )
        }
        let entryRecords = helperCorpus.entries.map(FuzzProgressDocument.CorpusEntryRecord.init(entry:))

        let document = FuzzProgressDocument(
            metadata: FuzzProgressDocument.Metadata(
                seed: 9,
                budgetNanoseconds: 60_000_000_000,
                consumedNanoseconds: 55_000_000_000,
                attemptsConsumed: 1000,
                lastCheckpointEpochSeconds: Date().timeIntervalSince1970,
                pcTableHash: 0xDEAD,
                edgeCount: 16
            ),
            clusters: [],
            snapshot: Array(entryRecords)
        )
        try store.write(document)

        let context = FuzzPersistenceContext(store: store, resumeEnabled: true)
        #expect(context.resumeDocument != nil)

        // The live source has 32 edges and a different mapping than the document's 16-edge cached hits. The hash mismatch (document says 0xDEAD, runtime has 0) forces re-attribution through the live source.
        let liveSource = SyntheticCoverageSource<Int>(edgeCount: 32, edges: { value in
            [abs(value) % 10 + 20]
        })

        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: gen,
            time: .seconds(60),
            settings: [.replay(9), .suppress(.all)],
            source: .injected(liveSource),
            configure: { configuration in
                configuration.attemptLimit = 50
            },
            persistence: context,
            property: { _ in .pass }
        )

        // Restore succeeded: the corpus carries entries from the predecessor's snapshot.
        #expect(report.coverage.corpusEntryCount >= 3)
        // The live source reports 32 edges, proving attribution came from the live source (the document stored 16-edge signatures that are now invalid).
        #expect(report.coverage.instrumentedEdges == 32)
        // Covered edges should be in the live source's range (20+), not the document's (0-3).
        #expect(report.coverage.coveredEdges > 0)
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
                attemptsConsumed: 1000,
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

    @Test("A restored entry the predecessor already recorded as failing does not recount its cluster")
    func restoredFailureDoesNotRecountItsCluster() throws {
        let report = try resumeWithOverlappingSnapshotEntry(predecessorRecordedFailure: true)
        let restored = try #require(report.clusters.first { $0.symptoms == ["PlantedFault"] })
        // The record's numbers, unchanged: the predecessor counted this failure already, so re-judging it must not tally the same evidence again.
        #expect(restored.instanceCount == 3)
        #expect(restored.reducedCount == 1)
        #expect(restored.firstSeenAttempt == 1)
    }

    @Test("A restored entry that passed for the predecessor and fails now counts as this run's evidence")
    func restoredEntryThatStartedFailingCounts() throws {
        let report = try resumeWithOverlappingSnapshotEntry(predecessorRecordedFailure: false)
        let restored = try #require(report.clusters.first { $0.symptoms == ["PlantedFault"] })
        // A build that starts failing an input the predecessor passed produces evidence nothing has counted, so the cluster gains a member and a reduction. The discovery index still comes from the record, because the failure belongs to no attempt of this run.
        #expect(restored.instanceCount == 4)
        #expect(restored.reducedCount == 2)
        #expect(restored.firstSeenAttempt == 1)
    }

    @Test("A resume whose predecessor consumed the whole budget reports the restored inventory, not the pointless-run error")
    func resumeWithConsumedBudget() throws {
        let directory = scratchDirectory()
        let store = FuzzProgressStore(directory: directory)
        defer {
            store.removeAll()
        }
        let gen = Gen.choose(in: 0 ... 100 as ClosedRange<Int>)

        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 1, maxRuns: UInt64.max)
        let (plantedValue, tree) = try #require(try interpreter.next())
        let sequence = ChoiceSequence.flatten(tree)
        let clusterRecord = FuzzProgressDocument.ClusterRecord(
            cluster: FaultCluster(
                restoredID: 0,
                reducedSequence: sequence,
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
        // The predecessor consumed the entire declared budget before it died, so the remaining slice is zero and this run evaluates nothing.
        try store.write(FuzzProgressDocument(
            metadata: FuzzProgressDocument.Metadata(
                seed: 9,
                budgetNanoseconds: 60_000_000_000,
                consumedNanoseconds: 60_000_000_000,
                attemptsConsumed: 1000,
                lastCheckpointEpochSeconds: Date().timeIntervalSince1970,
                pcTableHash: 0,
                edgeCount: 32
            ),
            clusters: [clusterRecord],
            snapshot: []
        ))
        let context = FuzzPersistenceContext(store: store, resumeEnabled: true)
        #expect(context.resumeDocument != nil)

        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: gen,
            time: .seconds(60),
            settings: [.replay(9), .suppress(.all)],
            source: .injected(resumeSource()),
            configure: nil,
            persistence: context,
            // Restore re-judges every cluster against the current build and drops the ones that now pass, so the fault has to still be a fault for the inventory to carry over.
            property: { $0 == plantedValue ? .fail(FailureSymptom(kind: "PlantedFault")) : .pass }
        )
        #expect(report.attempts.evaluated == 0)
        #expect(report.resumedFromCrash)
        // Symptom and description are re-derived from the live evaluation, not carried from the record: a predecessor's prose can describe a fault that no longer presents that way.
        #expect(report.clusters.contains { $0.symptoms == ["PlantedFault"] })

        // The recorded issues are the consumed-budget explanation and the restored inventory. The "asserts nothing" pointless-run error must not fire: the generator and budget are both fine, and blaming them would send the reader in the wrong direction.
        nonisolated(unsafe) var sawConsumedBudgetMessage = false
        withKnownIssue {
            __ExhaustRuntime.reportFuzzIssues(
                report: report,
                suppressIssueReporting: false,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
        } matching: { issue in
            if issue.description.contains("already consumed by predecessors that terminated abnormally") {
                sawConsumedBudgetMessage = true
            }
            return issue.description.contains("asserts nothing") == false
        }
        #expect(sawConsumedBudgetMessage)
    }
}

// MARK: - Helpers

private func scratchDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("exhaust-resume-tests")
        .appendingPathComponent(UUID().uuidString)
}

/// Resumes against a progress log whose planted cluster and sole snapshot entry are the same input, so re-judging the entry walks straight back into the cluster the record restored.
///
/// The predecessor's budget is fully consumed, so restore is the only thing that runs: no attempt of this run can reach the fault and move the counts on its own. `predecessorRecordedFailure` is the verdict the predecessor persisted for the entry, which is what decides whether the re-judged failure is evidence already counted or evidence this build produced.
private func resumeWithOverlappingSnapshotEntry(predecessorRecordedFailure: Bool) throws -> FuzzReport {
    let store = FuzzProgressStore(directory: scratchDirectory())
    defer {
        store.removeAll()
    }
    let gen = Gen.choose(in: 0 ... 100 as ClosedRange<Int>)

    var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 1, maxRuns: UInt64.max)
    let (plantedValue, tree) = try #require(try interpreter.next())
    let sequence = ChoiceSequence.flatten(tree)

    let helperCorpus = FuzzCorpus(edgeCount: 32)
    _ = helperCorpus.offer(
        sequence: sequence,
        tree: tree,
        hits: [(edge: abs(plantedValue) % 10, hitCount: 1)],
        convergence: 1.0,
        generation: 0,
        phase: .sampling,
        propertyFailed: predecessorRecordedFailure
    )

    let clusterRecord = FuzzProgressDocument.ClusterRecord(
        cluster: FaultCluster(
            restoredID: 0,
            reducedSequence: sequence,
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
    try store.write(FuzzProgressDocument(
        metadata: FuzzProgressDocument.Metadata(
            seed: 9,
            budgetNanoseconds: 60_000_000_000,
            consumedNanoseconds: 60_000_000_000,
            attemptsConsumed: 1000,
            lastCheckpointEpochSeconds: Date().timeIntervalSince1970,
            pcTableHash: 0,
            edgeCount: 32
        ),
        clusters: [clusterRecord],
        snapshot: helperCorpus.entries.map(FuzzProgressDocument.CorpusEntryRecord.init(entry:))
    ))

    let report = __ExhaustRuntime.runExploreTimeCore(
        gen: gen,
        time: .seconds(60),
        settings: [.replay(9), .suppress(.all)],
        source: .injected(resumeSource()),
        configure: nil,
        persistence: FuzzPersistenceContext(store: store, resumeEnabled: true),
        property: { $0 == plantedValue ? .fail(FailureSymptom(kind: "PlantedFault")) : .pass }
    )
    #expect(report.attempts.evaluated == 0)
    return report
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
