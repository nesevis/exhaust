// Crash recovery for the fuzz loop: checkpoints, the live breadcrumb, and predecessor restore.

import Foundation

extension FuzzRunner {
    // MARK: - Crash Recovery

    /// Creates the writer and live breadcrumb, restores predecessor state, and quarantines the crash region. First write activity of the run — a run that never starts leaves no files.
    func setUpPersistence() {
        guard let persistence = configuration.persistence else {
            return
        }
        progressWriter = FuzzProgressWriter(store: persistence.store)
        breadcrumb = FuzzBreadcrumb(fileURL: persistence.store.breadcrumbFileURL)
        breadcrumb?.clear()
        pcTableHashAtStart = SancovRuntime.pcTableHash()
        lastCheckpointNanoseconds = startNanoseconds

        if let document = persistence.resumeDocument {
            priorConsumedNanoseconds = document.metadata.consumedNanoseconds
            restore(from: document)
            ExhaustLog.notice(
                category: .propertyTest,
                event: "explore_time_resumed",
                metadata: [
                    "consumed_seconds": "\(document.metadata.consumedNanoseconds / 1_000_000_000)",
                    "restored_entries": "\(corpus.entries.count)",
                    "restored_clusters": "\(document.clusters.count)",
                ]
            )
        }
        if let survivor = persistence.survivor {
            corpus.quarantine(sequenceHash: survivor.candidateHash)
            if survivor.parentHash != 0 {
                corpus.quarantine(sequenceHash: survivor.parentHash)
            }
        }

        // Write one checkpoint synchronously before the first evaluation, so even a crash in the opening milliseconds leaves a parseable log on disk rather than nothing.
        try? persistence.store.write(makeCheckpointDocument(now: startNanoseconds))
    }

    /// Flushes outstanding checkpoints and removes the recovery state. Reaching this method at all means the run terminated normally — a surviving log is the crash signal, so a completed run must not leave one.
    func finishPersistence() {
        guard let persistence = configuration.persistence else {
            return
        }
        progressWriter?.flush()
        breadcrumb?.clear()
        persistence.store.removeAll()
    }

    /// Hands one checkpoint to the async writer when the interval elapsed or a new cluster forced one. The loop's cost is snapshotting value-type state (copy-on-write array grabs); record building, choice-sequence encoding, JSON serialization, and I/O all happen on the writer's queue.
    func checkpointIfDue() {
        guard let writer = progressWriter else {
            return
        }
        let now = monotonicNanoseconds()
        guard forceCheckpoint || now - lastCheckpointNanoseconds >= FuzzTunables.checkpointIntervalNanoseconds else {
            return
        }
        forceCheckpoint = false
        lastCheckpointNanoseconds = now

        let metadata = checkpointMetadata(now: now)
        let clusters = inventory.snapshot()
        let entries = corpus.entries
        let epoch = reportEpochNanoseconds
        writer.submit {
            FuzzProgressDocument(
                metadata: metadata,
                clusters: clusters.map { FuzzProgressDocument.ClusterRecord(cluster: $0, epochNanoseconds: epoch) },
                snapshot: entries.map(FuzzProgressDocument.CorpusEntryRecord.init(entry:))
            )
        }
    }

    /// The checkpoint metadata at `now`, continuing the logical run's consumed-time accounting across resumes.
    private func checkpointMetadata(now: UInt64) -> FuzzProgressDocument.Metadata {
        FuzzProgressDocument.Metadata(
            seed: configuration.seed,
            budgetNanoseconds: priorConsumedNanoseconds + configuration.budgetNanoseconds,
            consumedNanoseconds: priorConsumedNanoseconds + (now - startNanoseconds),
            lastCheckpointEpochSeconds: Date().timeIntervalSince1970,
            pcTableHash: pcTableHashAtStart,
            edgeCount: source.edgeCount
        )
    }

    /// Builds one document synchronously, for the startup checkpoint written before the first evaluation.
    private func makeCheckpointDocument(now: UInt64) -> FuzzProgressDocument {
        let epoch = reportEpochNanoseconds
        return FuzzProgressDocument(
            metadata: checkpointMetadata(now: now),
            clusters: inventory.snapshot().map { FuzzProgressDocument.ClusterRecord(cluster: $0, epochNanoseconds: epoch) },
            snapshot: corpus.entries.map(FuzzProgressDocument.CorpusEntryRecord.init(entry:))
        )
    }

    /// Rebuilds the corpus and inventory from a predecessor's document.
    ///
    /// Every entry is re-materialized in `.exact` mode — the tree is not persisted and mutations need it as the guided fallback. When the PC-table hash and edge count match the predecessor's, cached hits are trusted; otherwise each entry is re-attributed with one instrumented evaluation against the new edge ordering, and cluster signatures (stale edge indices) are dropped. Entries the current generator can no longer materialize are silently pruned — exactly the right pruning after a code change.
    private func restore(from document: FuzzProgressDocument) {
        let signaturesValid = document.metadata.pcTableHash == pcTableHashAtStart
            && document.metadata.edgeCount == source.edgeCount

        var restoredClusters: [FaultCluster] = []
        for record in document.clusters {
            guard let sequence = ChoiceSequenceCodec.decode(record.reducedSequence),
                  let phase = FuzzPhase(rawValue: record.discoveringPhase)
            else {
                continue
            }
            let signatures: [BitSet] = signaturesValid
                ? record.signatureIndices.map { indices in
                    var signature = BitSet(capacity: source.edgeCount)
                    for index in indices where index >= 0 && index < source.edgeCount {
                        signature.insert(index)
                    }
                    return signature
                }
                : []
            restoredClusters.append(FaultCluster(
                restoredID: restoredClusters.count,
                reducedSequence: sequence,
                reducedDescription: record.reducedDescription,
                reducedKey: record.reducedKey,
                signatures: signatures,
                symptoms: Set(record.symptoms.map(FailureSymptom.init(kind:))),
                instanceCount: record.instanceCount,
                reducedCount: record.reducedCount,
                firstSeenNanoseconds: reportEpochNanoseconds + record.firstSeenNanoseconds,
                lastSeenNanoseconds: reportEpochNanoseconds + record.lastSeenNanoseconds,
                firstSeenAttempt: record.firstSeenAttempt ?? 0,
                unnormalizedMemberCount: record.unnormalizedMemberCount ?? 0,
                discoveringPhase: phase
            ))
        }
        inventory.restore(clusters: restoredClusters)

        for record in document.snapshot {
            guard let sequence = ChoiceSequenceCodec.decode(record.sequence),
                  let phase = FuzzPhase(rawValue: record.phase)
            else {
                continue
            }
            let result = Materializer.materializeAny(erasedGen, prefix: sequence, mode: .exact)
            guard case let .success(anyValue, tree, _) = result, let value = anyValue as? Output else {
                continue
            }
            let hits: [(edge: Int, hitCount: UInt8)]
            if signaturesValid {
                hits = zip(record.hitEdges, record.hitCounts).map { (edge: $0.0, hitCount: $0.1) }
            } else {
                source.beginAttempt()
                if source.wantsValues {
                    source.noteValue(value)
                }
                // Attribution only — a failing entry's cluster was already restored, so no failure dispatch here.
                counts.recoveryInvocations += 1
                _ = property(value)
                var reattributed: [(edge: Int, hitCount: UInt8)] = []
                source.forEachHitEdge { edge, hitCount in
                    reattributed.append((edge, hitCount))
                }
                hits = reattributed
            }
            _ = corpus.offer(
                sequence: sequence,
                tree: tree,
                hits: hits,
                convergence: record.convergence,
                generation: record.generation,
                phase: phase,
                isBoundaryDerived: record.isBoundaryDerived,
                propertyFailed: record.propertyFailed
            )
        }
    }
}
