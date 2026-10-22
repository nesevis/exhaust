//
//  ReductionSession+RelaxRound.swift
//  Exhaust
//

// MARK: - Relax Round

extension ReductionSession {
    /// The state a relax round restores when its provisional result does not beat the checkpoint. Statistics recorded by exploitation passes are kept either way.
    ///
    /// Demotion counts are part of the checkpoint because exploitation passes record them against the perturbed graph, where they describe a different counterexample. The stripped-graph flag is part of it because exploitation rebuilds set it for the perturbed tree, and rollback rebuilds from the checkpoint's.
    private struct RelaxRoundCheckpoint {
        let incumbent: Counterexample
        let convergence: [ChoicePath: TransferableConvergence]
        let anyAccepted: Bool
        let hadUnresolvedReplacement: Bool
        let consecutiveRejectsByEncoder: [EncoderName: Int]
        let graphIsStripped: Bool
    }

    /// Accumulates a relax round's perturbation work, recorded once whether or not its result is kept.
    private struct RelaxRoundTally {
        let candidateCount: Int
        var materializationsUsed = 0
        var probeCounts = ReductionProbeCounts()
        var perturbationAccepted = false
    }

    /// Perturbs the counterexample with a structural replacement that may worsen it, exploits the perturbation with ordinary dispatch, and keeps the result only when it strictly precedes the checkpoint.
    ///
    /// The first perturbation that decodes to a failure is adopted; each one that does not spends one unit of ``ReductionTuning/relaxMaterializationBudget``. Exploitation rebuilds the graph and every source, seeds an empty rejection cache, and dispatches under the exploitation policy until its sources are exhausted or the deadline passes. Settlement restores the saved cache, then commits a strict improvement or restores the checkpoint: its demotion counts and stripped-graph flag, a graph rebuilt with no convergence carried over from exploitation, the checkpoint's own convergence, and no coupling evidence.
    ///
    /// - Returns: Whether the relax round committed an improvement.
    mutating func runRelaxRound() -> Bool {
        guard tuning.relaxMaterializationBudget > 0 else {
            return false
        }
        let checkpoint = RelaxRoundCheckpoint(
            incumbent: incumbent,
            convergence: Self.extractAllConvergence(from: graph),
            anyAccepted: anyAccepted,
            hadUnresolvedReplacement: hadUnresolvedReplacement,
            consecutiveRejectsByEncoder: consecutiveRejectsByEncoder,
            graphIsStripped: graphIsStripped
        )
        let budget = tuning.relaxMaterializationBudget
        ReductionLog.reducer("relax_round_start", isInstrumented: isInstrumented, metadata: [
            "seq_len": "\(incumbent.sequence.count)",
        ])
        var candidates = RelaxCandidateCursor(
            sequence: incumbent.sequence,
            graph: graph,
            limit: budget,
            isEncoderEnabled: isEncoderEnabled
        )
        guard candidates.candidateCount > 0 else {
            ReductionLog.reducer("relax_round_no_candidates", isInstrumented: isInstrumented, metadata: [:])
            return false
        }
        var tally = RelaxRoundTally(candidateCount: candidates.candidateCount)
        ReductionLog.reducer("relax_round_candidates", isInstrumented: isInstrumented, metadata: [
            "count": "\(candidates.candidateCount)",
        ])

        // Perturb.
        while tally.perturbationAccepted == false {
            guard deadline.isExpired == false,
                  tally.materializationsUsed < budget,
                  let candidate = candidates.next(),
                  deadline.isExpired == false
            else {
                return completeWithoutPerturbation(tally)
            }
            tally.probeCounts.recordEmission()
            // Perturbations may be larger than the incumbent, so ordinary reduction's cached rejections do not answer for them.
            let evaluation = CandidateEvaluator.evaluate(
                candidate,
                against: incumbent,
                using: .exact(materializePicks: true, admission: .standard),
                decoder: decoder,
                admits: { _ in true },
                cacheHit: false,
                cacheKey: nil,
                cache: &rejectCache,
                counts: &tally.probeCounts
            )
            guard case let .admitted(recovered, _) = evaluation else {
                tally.materializationsUsed += 1
                continue
            }
            tally.probeCounts.recordAcceptance()
            incumbent = recovered
            tally.perturbationAccepted = true
            ReductionLog.reducer("relax_round_perturbation_accepted", isInstrumented: isInstrumented, metadata: [
                "seq_len": "\(incumbent.sequence.count)",
            ])
        }

        // A deadline before exploitation keeps a directly improving perturbation and rolls back any other, without a rebuild, since the graph still describes the checkpoint.
        guard deadline.isExpired == false else {
            let improved = incumbent.sequence.shortLexPrecedes(checkpoint.incumbent.sequence)
            if improved {
                rebuildAndUpdateGraph()
                graphIsStripped = false
            } else {
                incumbent = checkpoint.incumbent
            }
            recordRelaxRound(tally, committed: improved)
            return improved
        }

        // Exploit. The perturbation decoded with picks materialized, so the rebuilt graph carries every arm.
        rebuildAndUpdateGraph()
        graphIsStripped = false
        let outerSources = sources
        sources = deadline.isExpired ? [] : prepareExploitationSources()
        ReductionLog.reducer("relax_round_exploitation_start", isInstrumented: isInstrumented, metadata: [
            "seq_len": "\(incumbent.sequence.count)", "sources": "\(sources.count)",
        ])
        let savedRejectCache = rejectCache
        rejectCache = rejectCache.emptied
        _ = dispatchCycle(policy: .exploitation)
        sources = outerSources

        // Settle.
        rejectCache = savedRejectCache
        let committed = incumbent.sequence.shortLexPrecedes(checkpoint.incumbent.sequence)
        recordRelaxRound(tally, committed: committed)
        if committed {
            ReductionLog.reducer("relax_round_committed", isInstrumented: isInstrumented, metadata: [
                "old_seq_len": "\(checkpoint.incumbent.sequence.count)", "new_seq_len": "\(incumbent.sequence.count)",
            ])
            return true
        }
        incumbent = checkpoint.incumbent
        anyAccepted = checkpoint.anyAccepted
        hadUnresolvedReplacement = checkpoint.hadUnresolvedReplacement
        consecutiveRejectsByEncoder = checkpoint.consecutiveRejectsByEncoder
        graphIsStripped = checkpoint.graphIsStripped
        // Exploitation floors describe the perturbed counterexample, so none may transfer onto the restored one.
        graph.convergenceStore.removeAll()
        rebuildAndUpdateGraph()
        graph.couplingDependents.removeAll()
        couplingTracker = CouplingTracker()
        Self.transferConvergence(checkpoint.convergence, to: &graph)
        ReductionLog.reducer("relax_round_rolled_back", isInstrumented: isInstrumented, metadata: [
            "seq_len": "\(incumbent.sequence.count)",
        ])
        return false
    }

    // MARK: - Helpers

    /// Records the round when no perturbation decoded within the budget.
    private mutating func completeWithoutPerturbation(_ tally: RelaxRoundTally) -> Bool {
        recordRelaxRound(tally, committed: false)
        ReductionLog.reducer("relax_round_no_perturbation", isInstrumented: isInstrumented, metadata: [:])
        return false
    }

    /// Records perturbation work once, whether or not the provisional result is kept, and appends the round to the relax log, which is research diagnostics only.
    private mutating func recordRelaxRound(_ tally: RelaxRoundTally, committed: Bool) {
        stats.recordStructuralRelax(tally.probeCounts)
        guard diagnostics.isEnabled else {
            return
        }
        stats.relaxRoundLog.append(RelaxRoundRecord(
            candidateCount: tally.candidateCount,
            materializationsUsed: tally.materializationsUsed,
            perturbationDecoded: tally.perturbationAccepted,
            committed: committed
        ))
    }
}
