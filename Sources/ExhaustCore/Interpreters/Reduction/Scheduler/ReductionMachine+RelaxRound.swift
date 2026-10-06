//
//  ReductionMachine+RelaxRound.swift
//  Exhaust
//

// MARK: - Structural Relax Round

extension ReductionMachine {
    /// Probes improving pivots without a checkpoint, because every accepted probe already precedes the current sequence.
    ///
    /// - Returns: True if a pivot was accepted.
    mutating func runImprovingPivotPass() throws -> Bool {
        guard isEncoderEnabled(.branchPivot) else {
            return false
        }
        return try runImprovingPivotProbes(deadlineCheck: makeDeadlineCheck())
    }

    /// Runs a structural excursion: checkpoints, applies a shortlex-worsening perturbation, reduces from it, and commits only if the result beats the checkpoint.
    ///
    /// - Returns: True if the excursion produced a net improvement (committed).
    mutating func runExcursion() throws -> Bool {
        guard isPostCycleActionEnabled(.excursion), tuning.relaxMaterializationBudget > 0 else {
            return false
        }
        let deadlineCheck = makeDeadlineCheck()
        let checkpointSequence = sequence
        let checkpointTree = tree
        let checkpointOutput = output
        let checkpointConvergence = ChoiceGraphScheduler.extractAllConvergence(from: graph)
        // The exploitation loop applies pass reports that set these per-cycle flags. On rollback the committed counterexample is unchanged, so the flags must be restored too. Otherwise a stale `anyAccepted` defers termination for a cycle that produced nothing.
        let checkpointAnyAccepted = anyAccepted
        let checkpointUnresolvedReplacement = hadUnresolvedReplacement

        ChoiceGraphScheduler.logReducer("relax_round_start", isInstrumented: isInstrumented, metadata: [
            "seq_len": "\(sequence.count)",
        ])

        let materializationBudget = tuning.relaxMaterializationBudget
        var candidates = RelaxCandidateCursor(
            sequence: sequence,
            graph: graph,
            limit: materializationBudget,
            isEncoderEnabled: isEncoderEnabled
        )

        guard candidates.candidateCount > 0 else {
            ChoiceGraphScheduler.logReducer("relax_round_no_candidates", isInstrumented: isInstrumented, metadata: [:])
            return false
        }

        ChoiceGraphScheduler.logReducer("relax_round_candidates", isInstrumented: isInstrumented, metadata: [
            "count": "\(candidates.candidateCount)",
        ])

        var perturbationAccepted = false
        var materializationsUsed = 0
        var probeCounts = ReductionProbeCounts()
        defer {
            if collectStats {
                stats.recordStructuralRelax(probeCounts)
            }
        }
        while materializationsUsed < materializationBudget {
            guard let candidate = candidates.next() else {
                break
            }
            guard deadlineCheck() == false else {
                break
            }
            probeCounts.recordEmission()
            let decoder: SequenceDecoder = .exact(materializePicks: true)
            var filterObservations: [UInt64: FilterObservation] = [:]

            let outcome = try decoder.decodeAny(
                candidate: candidate,
                gen: gen,
                tree: tree,
                originalSequence: sequence,
                property: wrappedProperty(for: candidate),
                filterObservations: &filterObservations
            )
            probeCounts.recordOutcome(outcome)

            if let result = outcome.reduction {
                probeCounts.recordAcceptance()
                sequence = result.sequence
                tree = result.tree
                output = result.output
                perturbationAccepted = true

                ChoiceGraphScheduler.logReducer("relax_round_perturbation_accepted", isInstrumented: isInstrumented, metadata: [
                    "seq_len": "\(sequence.count)",
                ])
                break
            }

            materializationsUsed += 1
        }

        guard perturbationAccepted else {
            if collectDiagnostics {
                stats.relaxRoundLog.append(RelaxRoundRecord(
                    candidateCount: candidates.candidateCount,
                    materializationsUsed: materializationsUsed,
                    perturbationDecoded: false,
                    committed: false
                ))
            }
            ChoiceGraphScheduler.logReducer("relax_round_no_perturbation", isInstrumented: isInstrumented, metadata: [:])
            return false
        }

        // The graph still describes the checkpoint here. Keep a directly improving perturbation on expiry; otherwise restore the checkpoint before allocating exploitation sources.
        if deadlineCheck() {
            let improved = sequence.shortLexPrecedes(checkpointSequence)
            if improved {
                _ = rebuildAndUpdateGraph()
            } else {
                sequence = checkpointSequence
                tree = checkpointTree
                output = checkpointOutput
            }
            if collectDiagnostics {
                stats.relaxRoundLog.append(RelaxRoundRecord(
                    candidateCount: candidates.candidateCount,
                    materializationsUsed: materializationsUsed,
                    perturbationDecoded: true,
                    committed: improved
                ))
            }
            return improved
        }

        _ = rebuildAndUpdateGraph()
        var exploitSources = deadlineCheck() ? [] : CandidateSourceBuilder.buildSources(from: graph)

        ChoiceGraphScheduler.logReducer("relax_round_exploitation_start", isInstrumented: isInstrumented, metadata: [
            "seq_len": "\(sequence.count)", "sources": "\(exploitSources.count)",
        ])

        let savedRejectCache = rejectCache
        rejectCache = []
        while true {
            guard let sourceIndex = ChoiceGraphScheduler.highestPrioritySourceIndex(exploitSources) else {
                break
            }
            guard let exploitTransformation = exploitSources[sourceIndex].next() else {
                exploitSources.swapAt(sourceIndex, exploitSources.count - 1)
                exploitSources.removeLast()
                continue
            }
            guard deadlineCheck() == false else {
                break
            }
            guard isEncoderEnabled(exploitTransformation.operation.encoderName) else {
                continue
            }
            guard exploitTransformation.operation.isValid(in: graph) else {
                continue
            }
            guard exploitTransformation.operation.requiresGenerator == false else {
                continue
            }

            let warmStarts = ChoiceGraphScheduler.extractWarmStarts(from: graph)
            let exploitScope = EncoderInput(
                transformation: exploitTransformation,
                baseSequence: sequence,
                tree: tree,
                graph: graph,
                warmStartRecords: warmStarts
            )

            var exploitEncoder = ChoiceGraphScheduler.selectEncoder(for: exploitTransformation.operation, gen: gen)
            exploitEncoder.start(scope: exploitScope)

            captureDispatchBaseline()
            var session = ProbeSession(
                encoder: exploitEncoder,
                transformation: exploitTransformation,
                boundValueFingerprint: nil,
                baseSequence: sequence,
                hasBind: sequence.contains { entry in
                    if case .bind = entry {
                        return true
                    }
                    return false
                }
            )
            let report = try session.runToCompletion(state: &self, deadlineCheck: deadlineCheck)

            _ = applyPassReport(report)

            if report.anyAccepted, report.anyRequiresRebuild {
                _ = rebuildAndUpdateGraph(
                    valueGuardExemptNodeIDs: report.acceptedLeafNodeIDs
                        .union(report.convergenceRecords.keys)
                )
                exploitSources = deadlineCheck() ? [] : CandidateSourceBuilder.buildSources(from: graph)
            }
        }
        rejectCache = savedRejectCache

        let excursionCommitted = sequence.shortLexPrecedes(checkpointSequence)
        if collectDiagnostics {
            stats.relaxRoundLog.append(RelaxRoundRecord(
                candidateCount: candidates.candidateCount,
                materializationsUsed: materializationsUsed,
                perturbationDecoded: true,
                committed: excursionCommitted
            ))
        }

        if excursionCommitted {
            ChoiceGraphScheduler.logReducer("relax_round_committed", isInstrumented: isInstrumented, metadata: [
                "old_seq_len": "\(checkpointSequence.count)", "new_seq_len": "\(sequence.count)",
            ])
            return true
        }

        sequence = checkpointSequence
        tree = checkpointTree
        output = checkpointOutput
        anyAccepted = checkpointAnyAccepted
        hadUnresolvedReplacement = checkpointUnresolvedReplacement
        _ = rebuildAndUpdateGraph()
        ChoiceGraphScheduler.transferConvergence(checkpointConvergence, to: &graph)

        ChoiceGraphScheduler.logReducer("relax_round_rolled_back", isInstrumented: isInstrumented, metadata: [
            "seq_len": "\(sequence.count)",
        ])
        return false
    }

    // MARK: - Improving Pivot Probes

    /// Probes improving pivots at non-minimal content and accepts the first that still fails the property.
    ///
    /// The next cycle minimizes the accepted arm under ordinary scheduling, so no exploitation runs here.
    private mutating func runImprovingPivotProbes(deadlineCheck: @escaping () -> Bool) throws -> Bool {
        let budget = tuning.relaxImprovingProbeBudget
        guard budget > 0 else {
            return false
        }
        var probesUsed = 0
        var probeCounts = ReductionProbeCounts()
        defer {
            if collectStats {
                stats.recordStructuralRelax(probeCounts)
                stats.relaxImprovingProbes += probesUsed
            }
        }
        var candidates = ImprovingPivotCandidateCursor(sequence: sequence, graph: graph, rejectCache: rejectCache, deadlineCheck: deadlineCheck)
        while probesUsed < budget {
            guard let probe = candidates.next(), deadlineCheck() == false else {
                break
            }
            let candidate = probe.sequence
            let probeHash = probe.probeHash
            probesUsed += 1
            probeCounts.recordEmission()
            let decoder: SequenceDecoder = .exact(materializePicks: true)
            var filterObservations: [UInt64: FilterObservation] = [:]
            let outcome = try decoder.decodeAny(
                candidate: candidate,
                gen: gen,
                tree: tree,
                originalSequence: sequence,
                property: wrappedProperty(for: candidate),
                filterObservations: &filterObservations
            )
            probeCounts.recordOutcome(outcome)

            guard let result = outcome.reduction, result.sequence.shortLexPrecedes(sequence) else {
                rejectCache.insert(probeHash)
                continue
            }
            probeCounts.recordAcceptance()
            sequence = result.sequence
            tree = result.tree
            output = result.output
            if collectStats {
                stats.relaxImprovingAcceptances += 1
            }
            _ = rebuildAndUpdateGraph()
            ChoiceGraphScheduler.logReducer("relax_round_improving_pivot_accepted", isInstrumented: isInstrumented, metadata: [
                "seq_len": "\(sequence.count)", "probes": "\(probesUsed)",
            ])
            return true
        }
        return false
    }

    /// Whether the improving phase has a probe to spend.
    var hasUnprobedImprovingPivot: Bool {
        guard isEncoderEnabled(.branchPivot), tuning.relaxImprovingProbeBudget > 0 else {
            return false
        }
        var cursor = ImprovingPivotCandidateCursor(sequence: sequence, graph: graph, rejectCache: rejectCache, deadlineCheck: makeDeadlineCheck())
        return cursor.next() != nil
    }
}
