// The progress log's on-disk document: crash-recovery state for one `time:` run.

import Foundation

/// Everything a resumed run needs: metadata, the append-only cluster records, and the most recent corpus snapshot.
///
/// The document is rewritten whole on each checkpoint with an atomic rename, so the cluster list is logically append-only (it only grows between writes) while the corpus snapshot has overwrite semantics. Choice sequences are the durable record — coverage signatures are a cache keyed by ``Metadata/pcTableHash`` and re-attributed on mismatch.
package struct SprawlProgressDocument: Codable, Sendable {
    /// Bumped on any structural change; a version mismatch means the log is ignored, never misread.
    package var version: Int

    package var metadata: Metadata
    package var clusters: [ClusterRecord]
    package var snapshot: [CorpusEntryRecord]

    package init(metadata: Metadata, clusters: [ClusterRecord], snapshot: [CorpusEntryRecord]) {
        version = Self.currentVersion
        self.metadata = metadata
        self.clusters = clusters
        self.snapshot = snapshot
    }

    package static let currentVersion = 1

    /// Run parameters and checkpoint bookkeeping.
    package struct Metadata: Codable, Sendable {
        /// The root seed, so a resumed run replays the same search decisions.
        package var seed: UInt64

        /// The full wall-clock budget of the original run in nanoseconds.
        package var budgetNanoseconds: UInt64

        /// Monotonic run time consumed as of the last checkpoint; a resumed run gets the remainder.
        package var consumedNanoseconds: UInt64

        /// Wall-clock time of the last checkpoint, for the staleness cutoff.
        package var lastCheckpointEpochSeconds: Double

        /// Hash of the instrumented PC table at write time, or 0 when unavailable. A mismatch on resume means edge indices moved: cached signatures are dropped and corpus entries are re-attributed.
        package var pcTableHash: UInt64

        /// The instrumented edge count at write time — the capacity of every serialised signature.
        package var edgeCount: Int

        package init(
            seed: UInt64,
            budgetNanoseconds: UInt64,
            consumedNanoseconds: UInt64,
            lastCheckpointEpochSeconds: Double,
            pcTableHash: UInt64,
            edgeCount: Int
        ) {
            self.seed = seed
            self.budgetNanoseconds = budgetNanoseconds
            self.consumedNanoseconds = consumedNanoseconds
            self.lastCheckpointEpochSeconds = lastCheckpointEpochSeconds
            self.pcTableHash = pcTableHash
            self.edgeCount = edgeCount
        }
    }

    /// One fault cluster, serialised for restore into ``FaultInventory``.
    package struct ClusterRecord: Codable, Sendable {
        package var id: Int
        package var reducedSequence: String
        package var reducedDescription: String
        package var symptoms: [String]
        package var instanceCount: Int
        package var reducedCount: Int
        package var discoveringPhase: String
        /// Run-relative timestamps (nanoseconds since the logical run's start), not raw monotonic readings — a resumed process has a different monotonic origin.
        package var firstSeenNanoseconds: UInt64
        package var lastSeenNanoseconds: UInt64
        /// Signature edge indices, one array per distinct signature. Dropped on PC-hash mismatch.
        package var signatureIndices: [[Int]]

        package init(cluster: FaultCluster, epochNanoseconds: UInt64) {
            id = cluster.id
            reducedSequence = ChoiceSequenceCodec.encode(cluster.reducedSequence)
            reducedDescription = cluster.reducedDescription
            symptoms = cluster.symptoms.map(\.kind).sorted()
            instanceCount = cluster.instanceCount
            reducedCount = cluster.reducedCount
            discoveringPhase = cluster.discoveringPhase.rawValue
            firstSeenNanoseconds = cluster.firstSeenNanoseconds >= epochNanoseconds
                ? cluster.firstSeenNanoseconds - epochNanoseconds
                : 0
            lastSeenNanoseconds = cluster.lastSeenNanoseconds >= epochNanoseconds
                ? cluster.lastSeenNanoseconds - epochNanoseconds
                : 0
            signatureIndices = cluster.signatures.map(\.indices)
        }
    }

    /// One corpus entry, serialised so restore can re-offer it in original admission order.
    package struct CorpusEntryRecord: Codable, Sendable {
        package var sequence: String
        /// Hit edges and their saturating counts, parallel arrays — the exact offer input, so restore rebuilds bucket masks and rarity identically.
        package var hitEdges: [Int]
        package var hitCounts: [UInt8]
        package var convergence: Double
        package var generation: Int
        package var phase: String
        package var isBoundaryDerived: Bool
        package var propertyFailed: Bool

        package init(entry: CorpusEntry) {
            sequence = ChoiceSequenceCodec.encode(entry.sequence)
            hitEdges = entry.hits.map(\.edge)
            hitCounts = entry.hits.map(\.hitCount)
            convergence = entry.convergence
            generation = entry.generation
            phase = entry.phase.rawValue
            isBoundaryDerived = entry.isBoundaryDerived
            propertyFailed = entry.propertyFailed
        }
    }
}
