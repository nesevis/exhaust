/// Retains provisional excursion work while the outer reduction cycle is suspended.
///
/// The nested dispatch loop borrows the machine's sequence, tree, and graph. Only settlement decides whether its result beats the checkpoint; rollback preserves the existing gate, diagnostic, and spent-work side effects.
struct ExcursionFrame {
    /// Owns the perturbation cursor before exploitation, then the nested loop and the rejection cache to restore at settlement.
    enum Step {
        case perturb(RelaxCandidateCursor)
        case prepareExploitation
        case exploit(DispatchLoop, savedRejectCache: Set<UInt64>)
        case settle(savedRejectCache: Set<UInt64>)
        case finished
    }

    /// Distinguishes a yielded unit of provisional work from the excursion's final commit decision.
    enum StepResult {
        case advanced(ReductionMachine.ExcursionStep)
        case completed(improved: Bool)
    }

    /// Restores the counterexample and cycle flags without undoing the work already recorded by exploitation passes.
    private struct Checkpoint {
        let sequence: ChoiceSequence
        let tree: ChoiceTree
        let output: Any
        let convergence: [ChoicePath: (origin: ConvergedOrigin, typeTag: TypeTag, bitPattern: UInt64?)]
        let anyAccepted: Bool
        let hadUnresolvedReplacement: Bool
    }

    private let checkpoint: Checkpoint
    private let materializationBudget: Int
    private let candidateCount: Int
    private var materializationsUsed = 0
    private var probeCounts = ReductionProbeCounts()
    private var perturbationAccepted = false
    private(set) var step: Step

    /// Captures the rollback state before preparing the same budgeted perturbation prefix used by synchronous excursions.
    init?(state: ReductionMachine) {
        guard state.isPostCycleActionEnabled(.excursion), state.tuning.relaxMaterializationBudget > 0 else {
            return nil
        }
        checkpoint = Checkpoint(
            sequence: state.sequence,
            tree: state.tree,
            output: state.output,
            convergence: ChoiceGraphScheduler.extractAllConvergence(from: state.graph),
            anyAccepted: state.anyAccepted,
            hadUnresolvedReplacement: state.hadUnresolvedReplacement
        )
        materializationBudget = state.tuning.relaxMaterializationBudget
        ChoiceGraphScheduler.logReducer("relax_round_start", isInstrumented: state.isInstrumented, metadata: [
            "seq_len": "\(state.sequence.count)",
        ])
        let candidates = RelaxCandidateCursor(
            sequence: state.sequence,
            graph: state.graph,
            limit: materializationBudget,
            isEncoderEnabled: state.isEncoderEnabled
        )
        guard candidates.candidateCount > 0 else {
            ChoiceGraphScheduler.logReducer("relax_round_no_candidates", isInstrumented: state.isInstrumented, metadata: [:])
            return nil
        }
        candidateCount = candidates.candidateCount
        step = .perturb(candidates)
        ChoiceGraphScheduler.logReducer("relax_round_candidates", isInstrumented: state.isInstrumented, metadata: [
            "count": "\(candidateCount)",
        ])
    }

    /// Performs one perturbation decode, nested dispatch step, or settlement; an expired excursion settles before starting another probe.
    mutating func advance(state: inout ReductionMachine) -> StepResult {
        guard state.isDeadlineExceeded() == false else {
            return .completed(improved: finishAtDeadline(state: &state))
        }
        switch step {
            case var .perturb(candidates):
                // Release the stored cursor before advancing its buffer, avoiding a copy of the retained splice prefix.
                step = .prepareExploitation
                guard materializationsUsed < materializationBudget,
                      let candidate = candidates.next(),
                      state.isDeadlineExceeded() == false
                else {
                    return completeWithoutPerturbation(state: &state)
                }
                probeCounts.recordEmission()
                let decoder: SequenceDecoder = .exact(materializePicks: true)
                var filterObservations: [UInt64: FilterObservation] = [:]
                let outcome = decoder.decodeAny(
                    candidate: candidate,
                    gen: state.gen,
                    tree: state.tree,
                    originalSequence: state.sequence,
                    property: state.wrappedProperty(for: candidate),
                    filterObservations: &filterObservations
                )
                probeCounts.recordOutcome(outcome)
                if let result = outcome.reduction {
                    probeCounts.recordAcceptance()
                    state.sequence = result.sequence
                    state.tree = result.tree
                    state.output = result.output
                    perturbationAccepted = true
                    ChoiceGraphScheduler.logReducer("relax_round_perturbation_accepted", isInstrumented: state.isInstrumented, metadata: [
                        "seq_len": "\(state.sequence.count)",
                    ])
                } else {
                    materializationsUsed += 1
                    step = .perturb(candidates)
                }
                return .advanced(.perturbed(accepted: perturbationAccepted))

            case .prepareExploitation:
                _ = state.rebuildAndUpdateGraph()
                var loop = DispatchLoop(policy: .exploitation)
                loop.sources = state.isDeadlineExceeded() ? [] : CandidateSourceBuilder.buildSources(from: state.graph)
                ChoiceGraphScheduler.logReducer("relax_round_exploitation_start", isInstrumented: state.isInstrumented, metadata: [
                    "seq_len": "\(state.sequence.count)", "sources": "\(loop.sources.count)",
                ])
                let savedRejectCache = state.rejectCache
                state.rejectCache = []
                step = .exploit(loop, savedRejectCache: savedRejectCache)
                return .advanced(.exploitationStarted(sourceCount: loop.sources.count))

            case .exploit(var loop, let savedRejectCache):
                // The frame must not retain the loop's sources across a mutating step.
                step = .settle(savedRejectCache: savedRejectCache)
                guard let transition = loop.step(state: &state) else {
                    return settleExploitation(savedRejectCache: savedRejectCache, state: &state)
                }
                if case .done = loop.subPhase {
                    step = .settle(savedRejectCache: savedRejectCache)
                } else {
                    step = .exploit(loop, savedRejectCache: savedRejectCache)
                }
                return .advanced(exploitationStep(transition))

            case let .settle(savedRejectCache):
                return settleExploitation(savedRejectCache: savedRejectCache, state: &state)

            case .finished:
                preconditionFailure("A settled excursion must be discarded by its host")
        }
    }

    /// Flushes an in-flight exploitation report before deciding whether to retain the provisional counterexample.
    ///
    /// Before exploitation the graph still describes the checkpoint, so a worsening perturbation rolls back without a rebuild. A directly improving perturbation is retained and rebuilds the graph once.
    mutating func finishAtDeadline(state: inout ReductionMachine) -> Bool {
        switch step {
            case .perturb:
                _ = completeWithoutPerturbation(state: &state)
                return false
            case .prepareExploitation:
                guard perturbationAccepted else {
                    _ = completeWithoutPerturbation(state: &state)
                    return false
                }
                let improved = state.sequence.shortLexPrecedes(checkpoint.sequence)
                if improved {
                    _ = state.rebuildAndUpdateGraph()
                } else {
                    state.sequence = checkpoint.sequence
                    state.tree = checkpoint.tree
                    state.output = checkpoint.output
                }
                recordRound(committed: improved, state: &state)
                _ = complete(improved: improved, state: &state)
                return improved
            case .exploit(var loop, let savedRejectCache):
                step = .settle(savedRejectCache: savedRejectCache)
                _ = loop.finishAtDeadline(state: &state)
                _ = settleExploitation(savedRejectCache: savedRejectCache, state: &state)
                return state.sequence.shortLexPrecedes(checkpoint.sequence)
            case let .settle(savedRejectCache):
                _ = settleExploitation(savedRejectCache: savedRejectCache, state: &state)
                return state.sequence.shortLexPrecedes(checkpoint.sequence)
            case .finished:
                return false
        }
    }

    /// Preserves the diagnostic record and rejection behavior when no perturbation decoded within the budget.
    private mutating func completeWithoutPerturbation(state: inout ReductionMachine) -> StepResult {
        recordRound(committed: false, state: &state)
        ChoiceGraphScheduler.logReducer("relax_round_no_perturbation", isInstrumented: state.isInstrumented, metadata: [:])
        return complete(improved: false, state: &state)
    }

    /// Restores the outer cache and commits only a strict improvement over the checkpoint, keeping rollback's existing side effects.
    private mutating func settleExploitation(savedRejectCache: Set<UInt64>, state: inout ReductionMachine) -> StepResult {
        state.rejectCache = savedRejectCache
        let committed = state.sequence.shortLexPrecedes(checkpoint.sequence)
        recordRound(committed: committed, state: &state)
        if committed {
            ChoiceGraphScheduler.logReducer("relax_round_committed", isInstrumented: state.isInstrumented, metadata: [
                "old_seq_len": "\(checkpoint.sequence.count)", "new_seq_len": "\(state.sequence.count)",
            ])
            return complete(improved: true, state: &state)
        }
        state.sequence = checkpoint.sequence
        state.tree = checkpoint.tree
        state.output = checkpoint.output
        state.anyAccepted = checkpoint.anyAccepted
        state.hadUnresolvedReplacement = checkpoint.hadUnresolvedReplacement
        _ = state.rebuildAndUpdateGraph()
        state.graph.couplingDependents.removeAll()
        state.couplingTracker = CouplingTracker()
        ChoiceGraphScheduler.transferConvergence(checkpoint.convergence, to: &state.graph)
        ChoiceGraphScheduler.logReducer("relax_round_rolled_back", isInstrumented: state.isInstrumented, metadata: [
            "seq_len": "\(state.sequence.count)",
        ])
        return complete(improved: false, state: &state)
    }

    /// Retains round diagnostics even when expiry interrupts a successful perturbation before exploitation starts.
    private func recordRound(committed: Bool, state: inout ReductionMachine) {
        if state.collectDiagnostics {
            state.stats.relaxRoundLog.append(RelaxRoundRecord(
                candidateCount: candidateCount,
                materializationsUsed: materializationsUsed,
                perturbationDecoded: perturbationAccepted,
                committed: committed
            ))
        }
    }

    /// Records perturbation work once, independently of whether the provisional result is retained.
    private mutating func complete(improved: Bool, state: inout ReductionMachine) -> StepResult {
        if state.collectStats {
            state.stats.recordStructuralRelax(probeCounts)
        }
        step = .finished
        return .completed(improved: improved)
    }

    /// Keeps nested-loop events observable while their elapsed time belongs to the excursion.
    private func exploitationStep(_ transition: ReductionMachine.Transition) -> ReductionMachine.ExcursionStep {
        switch transition {
            case let .dispatched(decision):
                return .dispatched(decision: decision)
            case let .encoded(encoder, cacheHit):
                return .encoded(encoder: encoder, cacheHit: cacheHit)
            case let .decoded(encoder, accepted):
                return .decoded(encoder: encoder, accepted: accepted)
            case let .passCompleted(encoder, accepted):
                return .passCompleted(encoder: encoder, accepted: accepted)
            case let .rebuilt(sequenceLength, structurallyChanged):
                return .rebuilt(sequenceLength: sequenceLength, structurallyChanged: structurallyChanged)
            default:
                preconditionFailure("An exploitation loop must not advance its host's cycle")
        }
    }
}
