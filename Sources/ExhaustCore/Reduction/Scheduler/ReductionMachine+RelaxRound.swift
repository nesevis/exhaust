//
//  ReductionMachine+RelaxRound.swift
//  Exhaust
//

// MARK: - Structural Relax Round

extension ReductionMachine {
    /// Probes improving pivots without a checkpoint, because every accepted probe already precedes the current sequence.
    ///
    /// - Returns: True if a pivot was accepted.
    mutating func runImprovingPivotPass() -> Bool {
        guard isEncoderEnabled(.branchPivot) else {
            return false
        }
        return runImprovingPivotProbes(deadlineCheck: makeDeadlineCheck())
    }

    /// Drives the same excursion continuation synchronously for callers that do not need cooperative transitions.
    mutating func runExcursion() -> Bool {
        guard var frame = ExcursionFrame(state: self) else {
            return false
        }
        while true {
            switch frame.advance(state: &self) {
                case .advanced:
                    continue
                case let .completed(improved):
                    return improved
            }
        }
    }

    /// Suspends the remaining post-cycle actions until the excursion settles its provisional counterexample.
    mutating func startExcursion(remaining: [ChoiceGraphScheduler.PostCycleAction]) -> Transition {
        guard let frame = ExcursionFrame(state: self) else {
            return .excursionCompleted(improved: false)
        }
        excursionFrame = frame
        phase = .excursion(remaining: remaining)
        return .excursionAdvanced(step: .started)
    }

    /// Lends core state to one excursion step without retaining its cursor or nested dispatch sources across mutation.
    mutating func stepExcursion(remaining: [ChoiceGraphScheduler.PostCycleAction]) -> Transition {
        guard var frame = excursionFrame else {
            preconditionFailure("An excursion phase must retain its checkpoint and continuation")
        }
        excursionFrame = nil
        switch frame.advance(state: &self) {
            case let .advanced(step):
                excursionFrame = frame
                return .excursionAdvanced(step: step)
            case let .completed(improved):
                if improved {
                    recordPostCycleAcceptance()
                }
                phase = remaining.isEmpty ? .checkTermination : .postCycle(remaining: remaining)
                return .excursionCompleted(improved: improved)
        }
    }

    // MARK: - Improving Pivot Probes

    /// Probes improving pivots at non-minimal content and accepts the first that still fails the property.
    ///
    /// The next cycle minimizes the accepted arm under ordinary scheduling, so no exploitation runs here.
    private mutating func runImprovingPivotProbes(deadlineCheck: @escaping () -> Bool) -> Bool {
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
            let outcome = decoder.decodeAny(
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
