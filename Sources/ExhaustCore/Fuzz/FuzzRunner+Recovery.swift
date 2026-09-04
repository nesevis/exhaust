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
        guard let writer = progressWriter, isRestoring == false else {
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

    /// Rebuilds the corpus and inventory from a predecessor's document, re-judging every restored item against the current build.
    ///
    /// A resume document exists only after an abnormal termination, so the run reading it is usually the run after a fix. Nothing persisted is taken on trust: every entry and every cluster is materialized and evaluated once, and the live verdict, hits, symptom, description, and cluster key replace the recorded ones. The PC-table hash fingerprints the control-flow graph, not behaviour, so a matching hash says nothing about whether the property still answers the same way; a changed constant, dependency, or ambient value moves the verdict and the covered edges while leaving the hash identical.
    ///
    /// What survives is one assumption: a cluster that still fails with the same reduced form is the same fault, and keeps its counts and timestamps. Clusters that now pass are dropped; entries that now fail are dispatched through the ordinary failure path so they reduce, classify, and report. Entries the current generator can no longer materialize are silently pruned — exactly the right pruning after a code change.
    private func restore(from document: FuzzProgressDocument) {
        // Reduction inside the restore loop reaches `checkpointIfDue()`, and a checkpoint written mid-restore would overwrite the predecessor's document with a half-restored corpus.
        isRestoring = true
        defer { isRestoring = false }

        var restoredClusters: [FaultCluster] = []
        for record in document.clusters {
            guard let sequence = ChoiceSequenceCodec.decode(record.reducedSequence),
                  let phase = FuzzPhase(rawValue: record.discoveringPhase)
            else {
                continue
            }
            guard let judged = rejudge(sequence) else {
                continue
            }
            let (value, tree, verdict, hits) = judged
            guard case let .fail(symptom) = verdict else {
                continue
            }
            var signature = BitSet(capacity: source.edgeCount)
            for (edge, _) in hits {
                signature.insert(edge)
            }
            restoredClusters.append(FaultCluster(
                restoredID: restoredClusters.count,
                reducedSequence: sequence,
                reducedDescription: renderValue(value),
                // Rekeyed from the materialized tree: the key derivation is a function of the generator, so the predecessor's key can no longer be the identity later classifications compare against. Two predecessor clusters can land on one key here, which `FaultInventory.restore(clusters:)` folds.
                reducedKey: ChoiceSequence.flatten(tree, skipBindInners: true).clusterKey,
                signatures: [signature],
                symptoms: [symptom],
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
            guard let (value, tree, verdict, hits) = rejudge(sequence) else {
                continue
            }
            let admission = corpus.offer(
                sequence: sequence,
                tree: tree,
                hits: hits,
                convergence: record.convergence,
                generation: record.generation,
                phase: phase,
                isBoundaryDerived: record.isBoundaryDerived,
                propertyFailed: verdict.isFailure,
                propertyDiscarded: verdict.isDiscard
            )
            if case let .fail(symptom) = verdict {
                handleFailure(
                    value: value,
                    tree: tree,
                    sequence: sequence,
                    symptom: symptom,
                    parentIndex: nil,
                    phase: phase,
                    coverageNovel: admission.isAdmitted,
                    // A restored entry's failure belongs to no attempt of this run.
                    attemptIndex: 0
                )
            }
        }
    }

    /// Materializes one persisted sequence and evaluates it once against the current build.
    ///
    /// The single evaluation is the contract: a stateful or flaky property can answer differently on a second call, and every consumer here (the verdict, the symptom, the signature, the corpus hits) has to describe the same run. Taking the persisted hits instead would seed the corpus with signatures for paths the current build no longer takes, and taking the persisted verdict would put a now-failing entry into the P(hit | pass) denominator.
    ///
    /// - Returns: Nil when the current generator can no longer materialize the sequence, which prunes the record.
    private func rejudge(
        _ sequence: ChoiceSequence
    ) -> (value: Output, tree: ChoiceTree, verdict: FuzzVerdict, hits: [(edge: Int, hitCount: UInt8)])? {
        let result = Materializer.materializeAny(erasedGen, prefix: sequence, mode: .exact)
        guard case let .success(anyValue, tree, _) = result, let value = anyValue as? Output else {
            return nil
        }
        let (verdict, hits) = attribute(value) { value in
            counts.recoveryInvocations += 1
            return withBreadcrumb(candidateHash: ZobristHash.hash(of: sequence), kind: .recovery) {
                property(value)
            }
        }
        return (value, tree, verdict, hits)
    }
}
