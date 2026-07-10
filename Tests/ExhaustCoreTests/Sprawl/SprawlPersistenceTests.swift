import ExhaustCore
import Foundation
import Testing

@Suite("Progress log codec, store, and breadcrumb")
struct SprawlPersistenceTests {
    @Test("Choice sequences round-trip through the codec with every entry kind")
    func codecRoundTrip() {
        let sequence: ChoiceSequence = [
            .group(true),
            .sequence(true, validRange: 0 ... 12, isLengthExplicit: true),
            .value(ChoiceSequenceValue.Value(
                choice: ChoiceValue(0xDEAD_BEEF, tag: .int64),
                validRange: 5 ... 500,
                isRangeExplicit: true
            )),
            .value(ChoiceSequenceValue.Value(
                choice: ChoiceValue(42, tag: .uint8),
                validRange: nil
            )),
            .just,
            .sequence(false),
            .branch(ChoiceSequenceValue.Branch(id: 2, branchCount: 5, fingerprint: 0xF00D)),
            .bind(true),
            .value(ChoiceSequenceValue.Value(
                choice: ChoiceValue(UInt64.max, tag: .double),
                validRange: 0 ... UInt64.max
            )),
            .bind(false),
            .group(false),
        ]
        let decoded = ChoiceSequenceCodec.decode(ChoiceSequenceCodec.encode(sequence))
        #expect(decoded == sequence)
    }

    @Test("Malformed and foreign payloads decode to nil, never to garbage")
    func codecRejectsMalformed() {
        #expect(ChoiceSequenceCodec.decode("not base64 at all!") == nil)
        // Valid base64, truncated content: a value marker with no payload behind it.
        #expect(ChoiceSequenceCodec.decode(Data([1, 8]).base64EncodedString()) == nil)
        // Unknown format version.
        #expect(ChoiceSequenceCodec.decode(Data([99]).base64EncodedString()) == nil)
        // The empty sequence is valid.
        #expect(ChoiceSequenceCodec.decode(Data([1]).base64EncodedString()) == ChoiceSequence())
    }

    @Test("Documents round-trip through the store and later writes overwrite earlier ones")
    func storeRoundTripAndOverwrite() throws {
        let store = SprawlProgressStore(directory: scratchDirectory())
        defer {
            store.removeAll()
        }

        try store.write(document(consumedNanoseconds: 1000, clusterCount: 0))
        try store.write(document(consumedNanoseconds: 2000, clusterCount: 2))

        let loaded = try #require(store.load(maxAgeSeconds: 60))
        #expect(loaded.metadata.consumedNanoseconds == 2000)
        #expect(loaded.clusters.count == 2)
        #expect(loaded.snapshot.count == 1)
    }

    @Test("Stale and missing logs are ignored")
    func staleness() throws {
        let store = SprawlProgressStore(directory: scratchDirectory())
        defer {
            store.removeAll()
        }
        #expect(store.load(maxAgeSeconds: 60) == nil)

        var stale = document(consumedNanoseconds: 1000, clusterCount: 1)
        stale.metadata.lastCheckpointEpochSeconds = Date().timeIntervalSince1970 - 90000
        try store.write(stale)
        #expect(store.load(maxAgeSeconds: 86400) == nil)
        #expect(store.load(maxAgeSeconds: 100_000) != nil)
    }

    @Test("A version mismatch invalidates the whole log")
    func versionMismatch() throws {
        let store = SprawlProgressStore(directory: scratchDirectory())
        defer {
            store.removeAll()
        }
        var future = document(consumedNanoseconds: 1000, clusterCount: 0)
        future.version = SprawlProgressDocument.currentVersion + 1
        try store.write(future)
        #expect(store.load(maxAgeSeconds: 86400) == nil)
    }

    @Test("The async writer serialises checkpoints in submission order")
    func writerOrdering() throws {
        let store = SprawlProgressStore(directory: scratchDirectory())
        defer {
            store.removeAll()
        }
        let writer = SprawlProgressWriter(store: store)
        let first = document(consumedNanoseconds: 1, clusterCount: 0)
        let second = document(consumedNanoseconds: 2, clusterCount: 1)
        writer.submit { first }
        writer.submit { second }
        writer.flush()
        let loaded = try #require(store.load(maxAgeSeconds: 60))
        #expect(loaded.metadata.consumedNanoseconds == 2)
        #expect(loaded.clusters.count == 1)
    }

    @Test("The breadcrumb records, reads back, and clears")
    func breadcrumbRoundTrip() throws {
        let directory = scratchDirectory()
        let fileURL = directory.appendingPathComponent("breadcrumb.bin")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let breadcrumb = try #require(SprawlBreadcrumb(fileURL: fileURL))
        #expect(SprawlBreadcrumb.readSurvivor(fileURL: fileURL) == nil)

        breadcrumb.record(candidateHash: 0xAAAA_BBBB, parentHash: 0x1111_2222)
        let survivor = try #require(SprawlBreadcrumb.readSurvivor(fileURL: fileURL))
        #expect(survivor.candidateHash == 0xAAAA_BBBB)
        #expect(survivor.parentHash == 0x1111_2222)

        breadcrumb.clear()
        #expect(SprawlBreadcrumb.readSurvivor(fileURL: fileURL) == nil)
    }

    @Test("Quarantined hashes leave parent selection and stay out on re-admission")
    func corpusQuarantine() {
        let corpus = SprawlCorpus(edgeCount: 8)
        var sequences: [ChoiceSequence] = []
        for value in 0 ..< 4 {
            let sequence: ChoiceSequence = [
                .value(ChoiceSequenceValue.Value(
                    choice: ChoiceValue(UInt64(value), tag: .int64),
                    validRange: nil
                )),
            ]
            sequences.append(sequence)
            let admission = corpus.offer(
                sequence: sequence,
                tree: .just,
                hits: [(edge: value, hitCount: 1)],
                convergence: 1.0,
                generation: 0,
                phase: .sampling
            )
            guard case .admitted = admission else {
                Issue.record("Expected admission for entry \(value)")
                return
            }
        }
        #expect(corpus.mutableTierIndices.count == 4)

        let quarantinedHash = ZobristHash.hash(of: sequences[1])
        corpus.quarantine(sequenceHash: quarantinedHash)
        #expect(corpus.mutableTierIndices.count == 3)
        for draw in stride(from: 0.0, to: 1.0, by: 0.05) {
            if let (_, entry) = corpus.pickParent(random: draw) {
                #expect(entry.hash != quarantinedHash)
            }
        }
    }

    #if os(macOS)
        @Test("The breadcrumb survives a Swift trap in a child process", .timeLimit(.minutes(2)))
        func breadcrumbSurvivesTrap() throws {
            let directory = scratchDirectory()
            defer {
                try? FileManager.default.removeItem(at: directory)
            }
            let crumbURL = directory.appendingPathComponent("breadcrumb.bin")
            let scriptURL = directory.appendingPathComponent("probe.swift")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try trapProbeSource.write(to: scriptURL, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["swift", scriptURL.path, crumbURL.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()

            // fatalError kills the child via an uncaught signal; a zero exit would mean the trap never fired.
            #expect(process.terminationStatus != 0 || process.terminationReason == .uncaughtSignal)

            let survivor = try #require(SprawlBreadcrumb.readSurvivor(fileURL: crumbURL))
            #expect(survivor.candidateHash == 0xDEAD_BEEF_CAFE_F00D)
            #expect(survivor.parentHash == 0x1122_3344_5566_7788)
        }
    #endif
}

// MARK: - Helpers

private func scratchDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("exhaust-persistence-tests")
        .appendingPathComponent(UUID().uuidString)
}

private func document(consumedNanoseconds: UInt64, clusterCount: Int) -> SprawlProgressDocument {
    let sequence: ChoiceSequence = [
        .value(ChoiceSequenceValue.Value(choice: ChoiceValue(7, tag: .int64), validRange: nil)),
    ]
    let clusters = (0 ..< clusterCount).map { index in
        SprawlProgressDocument.ClusterRecord(
            cluster: FaultCluster(
                restoredID: index,
                reducedSequence: sequence,
                reducedDescription: "\(index)",
                signatures: [],
                symptoms: [.returnedFalse],
                instanceCount: 1,
                reducedCount: 1,
                firstSeenNanoseconds: 100,
                lastSeenNanoseconds: 200,
                discoveringPhase: .sprawl
            ),
            epochNanoseconds: 0
        )
    }
    // Build the entry through a real admission — CorpusEntry's memberwise initializer is internal to ExhaustCore.
    let corpus = SprawlCorpus(edgeCount: 8)
    _ = corpus.offer(
        sequence: sequence,
        tree: .just,
        hits: [(edge: 1, hitCount: 3)],
        convergence: 1.0,
        generation: 0,
        phase: .sampling
    )
    let entry = corpus.entries[0]
    return SprawlProgressDocument(
        metadata: SprawlProgressDocument.Metadata(
            seed: 9,
            budgetNanoseconds: 60_000_000_000,
            consumedNanoseconds: consumedNanoseconds,
            lastCheckpointEpochSeconds: Date().timeIntervalSince1970,
            pcTableHash: 0,
            edgeCount: 8
        ),
        clusters: clusters,
        snapshot: [SprawlProgressDocument.CorpusEntryRecord(entry: entry)]
    )
}

private let trapProbeSource = """
import Darwin
import Foundation

let path = CommandLine.arguments[1]
let descriptor = open(path, O_RDWR | O_CREAT, 0o644)
precondition(descriptor >= 0)
precondition(ftruncate(descriptor, 16) == 0)
guard let mapping = mmap(nil, 16, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0), mapping != MAP_FAILED else {
    preconditionFailure("mmap failed")
}
mapping.storeBytes(of: UInt64(0xDEAD_BEEF_CAFE_F00D).littleEndian, toByteOffset: 0, as: UInt64.self)
mapping.storeBytes(of: UInt64(0x1122_3344_5566_7788).littleEndian, toByteOffset: 8, as: UInt64.self)
fatalError("planted trap: the breadcrumb above must survive this")
"""
