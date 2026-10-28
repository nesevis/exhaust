import ExhaustCore
import ExhaustSupport
import Foundation
import Testing
@testable import Exhaust

@Suite("Checkpoint store reservation")
struct FuzzPersistenceReservationTests {
    @Test("Directory creation failures remain typed and never enter the reserved body")
    func reservationDirectoryFailure() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data().write(to: base)
        let store = ReservationFixture.store(base: base, seed: 1)
        let failure = await #expect(throws: FuzzPersistenceError.self) {
            try await __ExhaustRuntime.withReservedFuzzPersistence(
                store: store,
                resumeEnabled: ReservationFixture.resumeEnabled
            ) { _ in
                Issue.record("Reservation entered its body after directory creation failed")
            }
        }
        #expect(failure?.description.contains("Cannot create the lock directory") == true)
    }

    @Test("Parallel seed campaigns recover their own checkpoints and breadcrumbs")
    func parallelCampaignRecovery() async throws {
        let base = ReservationFixture.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let firstStore = ReservationFixture.store(base: base, seed: 1)
        let secondStore = ReservationFixture.store(base: base, seed: 2)
        try await ReservationFixture.withReservedPersistence(store: firstStore) { first in
            try await ReservationFixture.withReservedPersistence(store: secondStore) { second in
                #expect(first.store.directory != second.store.directory)
                try first.store.write(ReservationFixture.document(consumedNanoseconds: 100, clusterCount: 1))
                try second.store.write(ReservationFixture.document(consumedNanoseconds: 200, clusterCount: 2))
                let firstCrumb = try #require(FuzzBreadcrumb(
                    fileURL: first.store.breadcrumbFileURL,
                    recordsCandidateSequence: false
                ))
                let secondCrumb = try #require(FuzzBreadcrumb(
                    fileURL: second.store.breadcrumbFileURL,
                    recordsCandidateSequence: false
                ))
                firstCrumb.record(candidateHash: 101, parentHash: 0, kind: .search)
                secondCrumb.record(candidateHash: 202, parentHash: 0, kind: .search)
                await #expect(throws: FuzzPersistenceError.self) {
                    try await ReservationFixture.withReservedPersistence(store: firstStore) { _ in }
                }
            }
        }
        try await ReservationFixture.withReservedPersistence(store: firstStore) { first in
            try await ReservationFixture.withReservedPersistence(store: secondStore) { second in
                #expect(first.resumeDocument?.metadata.consumedNanoseconds == 100)
                #expect(second.resumeDocument?.metadata.consumedNanoseconds == 200)
                #expect(first.survivor?.candidateHash == 101)
                #expect(second.survivor?.candidateHash == 202)
                first.store.removeAll()
                #expect(second.store.load(maxAgeSeconds: 60)?.clusters.count == 2)
                // Deleting completed state must not unlink the live ownership lock.
                await #expect(throws: FuzzPersistenceError.self) {
                    try await ReservationFixture.withReservedPersistence(store: firstStore) { _ in }
                }
            }
        }
    }

    @Test("Test identity and macro column isolate shared helper call sites")
    func sharedCallSiteIsolation() async throws {
        let base = ReservationFixture.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let stores = [("first", UInt(1)), ("second", UInt(1)), ("first", UInt(2))].map { identity, column in
            FuzzProgressStore(
                fileID: "Campaigns/Shared.swift",
                line: 10,
                column: column,
                testIdentity: identity,
                seed: 1,
                baseDirectory: base
            )
        }
        try await ReservationFixture.withReservedPersistence(store: stores[0]) { first in
            try await ReservationFixture.withReservedPersistence(store: stores[1]) { second in
                try await ReservationFixture.withReservedPersistence(store: stores[2]) { third in
                    #expect(Set([first.store.directory, second.store.directory, third.store.directory]).count == 3)
                }
            }
        }
    }

    @Test("Overlapping owners cannot share one resolved seed's recovery store")
    func seedOwnership() async throws {
        let base = ReservationFixture.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ReservationFixture.store(base: base, seed: 1)
        try await ReservationFixture.withReservedPersistence(store: store) { _ in
            let error = await #expect(throws: FuzzPersistenceError.self) {
                try await ReservationFixture.withReservedPersistence(store: store) { _ in }
            }
            #expect(error?.description.contains("Another campaign owns this checkpoint store") == true)
        }
    }

    @Test("Generated seeds isolate overlapping campaigns and recover abandoned state exactly once")
    func generatedSeedRecovery() async throws {
        let base = ReservationFixture.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = ReservationFixture.campaign(base: base)
        let second = ReservationFixture.campaign(base: base)
        let firstSeed = try first.configuration.resolution.get().seed
        let secondSeed = try second.configuration.resolution.get().seed
        #expect(firstSeed != secondSeed)
        #expect(first.store.directory.lastPathComponent.hasSuffix("-seed-\(firstSeed)"))
        #expect(second.store.directory.lastPathComponent.hasSuffix("-seed-\(secondSeed)"))

        try await ReservationFixture.withReservedPersistence(store: first.store) { persistence in
            try persistence.store.write(ReservationFixture.document(consumedNanoseconds: 100, clusterCount: 1))
            let breadcrumb = try #require(FuzzBreadcrumb(fileURL: persistence.store.breadcrumbFileURL, recordsCandidateSequence: false))
            breadcrumb.record(candidateHash: 101, parentHash: 0, kind: .search)
            try await __ExhaustRuntime.withReservedFuzzPersistence(
                store: second.store, resumeEnabled: true, recoverUnseeded: true
            ) { concurrent in
                #expect(concurrent.resumeDocument == nil)
                #expect(first.store.load(maxAgeSeconds: 60)?.clusters.count == 1)
            }
        }

        try await __ExhaustRuntime.withReservedFuzzPersistence(
            store: second.store, resumeEnabled: true, recoverUnseeded: true
        ) { recovered in
            #expect(recovered.resumeDocument?.metadata.consumedNanoseconds == 100)
            #expect(recovered.resumeDocument?.clusters.count == 1)
            #expect(recovered.survivor?.candidateHash == 101)
            #expect(recovered.store.directory == second.store.directory)
            #expect(FileManager.default.fileExists(atPath: first.store.directory.path) == false)
            #expect(FileManager.default.fileExists(atPath: first.store.lockFileURL.path))
            let third = ReservationFixture.campaign(base: base)
            // A second newcomer cannot claim the predecessor while its new owner is active.
            await #expect(throws: Never.self) {
                try await __ExhaustRuntime.withReservedFuzzPersistence(
                    store: third.store, resumeEnabled: true, recoverUnseeded: true
                ) { other in
                    #expect(other.resumeDocument == nil)
                    #expect(other.survivor == nil)
                }
            }
        }
    }

    @Test("Explicit replay and disabled recovery leave other seeds' checkpoints alone", arguments: [true, false])
    func recoverySelection(replay: Bool) async throws {
        let base = ReservationFixture.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let predecessor = ReservationFixture.campaign(base: base)
        try predecessor.store.write(ReservationFixture.document(consumedNanoseconds: 100, clusterCount: 1))
        let next = ReservationFixture.campaign(base: base)
        try await __ExhaustRuntime.withReservedFuzzPersistence(
            store: next.store, resumeEnabled: replay, recoverUnseeded: !replay
        ) { persistence in
            #expect(persistence.resumeDocument == nil)
            #expect(predecessor.store.load(maxAgeSeconds: 60)?.clusters.count == 1)
            #expect(FileManager.default.fileExists(atPath: next.store.directory.path) == false)
        }
    }

    @Test("Recovery never adopts a different test's checkpoint")
    func recoveryTestIsolation() async throws {
        let base = ReservationFixture.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let predecessor = ReservationFixture.campaign(base: base, testID: "other")
        try predecessor.store.write(ReservationFixture.document(consumedNanoseconds: 100, clusterCount: 1))
        let next = ReservationFixture.campaign(base: base)
        try await __ExhaustRuntime.withReservedFuzzPersistence(
            store: next.store, resumeEnabled: true, recoverUnseeded: true
        ) { persistence in
            #expect(persistence.resumeDocument == nil)
            #expect(predecessor.store.load(maxAgeSeconds: 60)?.clusters.count == 1)
        }
    }

    @Test("A throwing persistence scope releases ownership even if its context escapes")
    func throwingScopeReleasesOwnership() async throws {
        let base = ReservationFixture.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ReservationFixture.store(base: base, seed: 1)
        var escaped: FuzzPersistenceContext?
        await #expect(throws: PersistenceScopeFailure.self) {
            try await ReservationFixture.withReservedPersistence(store: store) { context in
                escaped = context
                throw PersistenceScopeFailure()
            }
        }
        try await ReservationFixture.withReservedPersistence(store: store) { current in
            #expect(escaped?.store.directory == current.store.directory)
        }
    }
}

// MARK: - Helpers

private struct PersistenceScopeFailure: Error {}

/// Builds call-site stores and checkpoint documents, and runs throwing fixture code inside the production reservation scope.
private enum ReservationFixture {
    static func campaign(base: URL, testID: String = "Campaigns.seeds") -> FuzzCampaignContext {
        FuzzCampaignContext(
            fileID: "Campaigns/Seeds.swift",
            filePath: "/tests/Seeds.swift",
            line: 10,
            column: 5,
            testID: testID,
            testName: "seeds",
            seed: nil,
            kind: .value,
            time: .seconds(60),
            environment: [CampaignWire.stateDirectoryKey: base.path]
        )
    }

    static var resumeEnabled: Bool {
        ProcessInfo.processInfo.environment[CampaignWire.resumeKey] != "0"
    }

    /// Preserves a throwing body's error while reusing the same typed reservation and lifetime scope.
    static func withReservedPersistence<Result>(
        store: FuzzProgressStore,
        body: (FuzzPersistenceContext) async throws -> Result
    ) async throws -> Result {
        let result: Swift.Result<Result, any Error> = try await __ExhaustRuntime.withReservedFuzzPersistence(
            store: store,
            resumeEnabled: resumeEnabled
        ) { context in
            do {
                return try await .success(body(context))
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    static func store(base: URL, seed: UInt64?) -> FuzzProgressStore {
        FuzzProgressStore(
            fileID: "Campaigns/Seeds.swift",
            line: 10,
            column: 5,
            testIdentity: "Campaigns.seeds",
            seed: seed,
            baseDirectory: base
        )
    }

    static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("exhaust-reservation-tests")
            .appendingPathComponent(UUID().uuidString)
    }

    static func document(consumedNanoseconds: UInt64, clusterCount: Int) -> FuzzProgressDocument {
        let sequence: ChoiceSequence = [
            .value(ChoiceSequenceValue.Value(choice: ChoiceValue(7, tag: .int64), validRange: nil)),
        ]
        let clusters = (0 ..< clusterCount).map { index in
            FuzzProgressDocument.ClusterRecord(
                cluster: FaultCluster(
                    restoredID: index,
                    reducedSequence: sequence,
                    reducedDescription: "\(index)",
                    reducedKey: "\(index)",
                    signatures: [],
                    symptoms: [.returnedFalse],
                    instanceCount: 1,
                    reducedCount: 1,
                    firstSeenNanoseconds: 100,
                    lastSeenNanoseconds: 200,
                    firstSeenAttempt: 1,
                    unnormalizedMemberCount: 0,
                    discoveringPhase: .mutation
                ),
                epochNanoseconds: 0
            )
        }
        // Build the entry through a real admission — CorpusEntry's memberwise initializer is internal to ExhaustCore.
        let corpus = FuzzCorpus(edgeCount: 8)
        _ = corpus.offer(
            sequence: sequence,
            tree: .just,
            hits: [(edge: 1, hitCount: 3)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling
        )
        let entry = corpus.entries[0]
        return FuzzProgressDocument(
            metadata: FuzzProgressDocument.Metadata(
                seed: 9,
                budgetNanoseconds: 60_000_000_000,
                consumedNanoseconds: consumedNanoseconds,
                attemptsConsumed: 0,
                lastCheckpointEpochSeconds: Date().timeIntervalSince1970,
                pcTableHash: 0,
                edgeCount: 8
            ),
            clusters: clusters,
            snapshot: [FuzzProgressDocument.CorpusEntryRecord(entry: entry)]
        )
    }
}
