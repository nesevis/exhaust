//
//  ScopedReductionRunner+RelaxRound.swift
//  Exhaust
//

// MARK: - Relax Round

extension ScopedReductionRunner {
    /// The state a relax round restores when its provisional result does not beat the checkpoint. Work already recorded by exploitation passes is kept either way.
    private struct RelaxRoundCheckpoint {
        let sequence: ChoiceSequence
        let tree: ChoiceTree
        let output: Any
        let convergence: [ChoicePath: TransferableConvergence]
        let anyAccepted: Bool
        let hadUnresolvedReplacement: Bool
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
    /// The first perturbation that decodes to a failure is adopted; each one that does not spends one unit of ``ScopedReductionTuning/relaxMaterializationBudget``. Exploitation rebuilds the graph and every source without bind-inner deferral, seeds an empty rejection cache, and dispatches under the exploitation policy until its sources are exhausted or the deadline passes. Settlement restores the saved cache, then commits a strict improvement or restores the checkpoint, rebuilding its graph, clearing coupling evidence, and transferring the checkpoint's convergence.
    ///
    /// - Returns: Whether the relax round committed an improvement.
    mutating func runRelaxRound() -> Bool {
        guard isPostCycleActionEnabled(.relaxRound), tuning.relaxMaterializationBudget > 0 else {
            return false
        }
        let checkpoint = RelaxRoundCheckpoint(
            sequence: sequence,
            tree: tree,
            output: output,
            convergence: Self.extractAllConvergence(from: graph),
            anyAccepted: anyAccepted,
            hadUnresolvedReplacement: hadUnresolvedReplacement
        )
        let budget = tuning.relaxMaterializationBudget
        Self.log("relax_round_start", isInstrumented: isInstrumented, metadata: [
            "seq_len": "\(sequence.count)",
        ])
        var candidates = ScopedRelaxCandidateCursor(
            sequence: sequence,
            graph: graph,
            limit: budget,
            isEncoderEnabled: isEncoderEnabled
        )
        guard candidates.candidateCount > 0 else {
            Self.log("relax_round_no_candidates", isInstrumented: isInstrumented, metadata: [:])
            return false
        }
        var tally = RelaxRoundTally(candidateCount: candidates.candidateCount)
        Self.log("relax_round_candidates", isInstrumented: isInstrumented, metadata: [
            "count": "\(candidates.candidateCount)",
        ])

        // Perturb.
        while tally.perturbationAccepted == false {
            guard isDeadlineExceeded() == false,
                  tally.materializationsUsed < budget,
                  let candidate = candidates.next(),
                  isDeadlineExceeded() == false
            else {
                return completeWithoutPerturbation(tally)
            }
            tally.probeCounts.recordEmission()
            let sequenceDecoder: SequenceDecoder = .exact(materializePicks: true)
            var filterObservations: [UInt64: FilterObservation] = [:]
            let outcome = sequenceDecoder.decodeAny(
                candidate: candidate,
                gen: generator,
                tree: tree,
                originalSequence: sequence,
                property: decoder.wrappedProperty(for: candidate),
                filterObservations: &filterObservations
            )
            tally.probeCounts.recordOutcome(outcome)
            guard let result = outcome.reduction else {
                tally.materializationsUsed += 1
                continue
            }
            tally.probeCounts.recordAcceptance()
            sequence = result.sequence
            tree = result.tree
            output = result.output
            tally.perturbationAccepted = true
            Self.log("relax_round_perturbation_accepted", isInstrumented: isInstrumented, metadata: [
                "seq_len": "\(sequence.count)",
            ])
        }

        // A deadline before exploitation keeps a directly improving perturbation and rolls back any other, without a rebuild, since the graph still describes the checkpoint.
        guard isDeadlineExceeded() == false else {
            let improved = sequence.shortLexPrecedes(checkpoint.sequence)
            if improved {
                rebuildAndUpdateGraph()
            } else {
                sequence = checkpoint.sequence
                tree = checkpoint.tree
                output = checkpoint.output
            }
            recordRelaxRound(tally, committed: improved)
            completeRelaxRound(tally)
            return improved
        }

        // Exploit.
        rebuildAndUpdateGraph()
        let outerSources = sources
        sources = isDeadlineExceeded() ? [] : prepareExploitationSources()
        Self.log("relax_round_exploitation_start", isInstrumented: isInstrumented, metadata: [
            "seq_len": "\(sequence.count)", "sources": "\(sources.count)",
        ])
        let savedRejectCache = rejectCache
        rejectCache = []
        _ = dispatchCycle(policy: .exploitation)
        sources = outerSources

        // Settle.
        rejectCache = savedRejectCache
        let committed = sequence.shortLexPrecedes(checkpoint.sequence)
        recordRelaxRound(tally, committed: committed)
        if committed {
            Self.log("relax_round_committed", isInstrumented: isInstrumented, metadata: [
                "old_seq_len": "\(checkpoint.sequence.count)", "new_seq_len": "\(sequence.count)",
            ])
            completeRelaxRound(tally)
            return true
        }
        sequence = checkpoint.sequence
        tree = checkpoint.tree
        output = checkpoint.output
        anyAccepted = checkpoint.anyAccepted
        hadUnresolvedReplacement = checkpoint.hadUnresolvedReplacement
        rebuildAndUpdateGraph()
        graph.couplingDependents.removeAll()
        couplingTracker = CouplingTracker()
        Self.transferConvergence(checkpoint.convergence, to: &graph)
        Self.log("relax_round_rolled_back", isInstrumented: isInstrumented, metadata: [
            "seq_len": "\(sequence.count)",
        ])
        completeRelaxRound(tally)
        return false
    }

    // MARK: - Helpers

    /// Records the round when no perturbation decoded within the budget.
    private mutating func completeWithoutPerturbation(_ tally: RelaxRoundTally) -> Bool {
        recordRelaxRound(tally, committed: false)
        Self.log("relax_round_no_perturbation", isInstrumented: isInstrumented, metadata: [:])
        completeRelaxRound(tally)
        return false
    }

    /// Records perturbation work once, whether or not the provisional result is kept.
    private mutating func completeRelaxRound(_ tally: RelaxRoundTally) {
        if collectStats {
            stats.recordStructuralRelax(tally.probeCounts)
        }
    }

    /// Appends the round to the relax log. Research diagnostics only.
    private mutating func recordRelaxRound(_ tally: RelaxRoundTally, committed: Bool) {
        guard collectDiagnostics else {
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
