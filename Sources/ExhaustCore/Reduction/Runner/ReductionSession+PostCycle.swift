//
//  ReductionSession+PostCycle.swift
//  Exhaust
//

// MARK: - Post-Cycle Actions

extension ReductionSession {
    /// Runs the cycle's post-cycle actions in order, stopping at the deadline.
    mutating func runPostCycleActions(_ actions: [PostCycleAction]) -> PhaseOutcome {
        for action in actions {
            guard deadline.isExpired == false else {
                return .deadline
            }
            switch action {
                case .confirmConvergence:
                    confirmConvergence()
                    stepTimer.charge(.convergenceConfirmation)
                case .relationPass:
                    let previousOwner = stepTimer.beginOwnership(.relationPass)
                    runRelationPass()
                    stepTimer.endOwnership(restoring: previousOwner)
                case .improvingPivots:
                    if runImprovingPivotPass() {
                        recordPostCycleAcceptance()
                    }
                    stepTimer.charge(.relaxRound)
                case .stagedJointPass:
                    let previousOwner = stepTimer.beginOwnership(.stagedJointPass)
                    runStagedJointPass()
                    stepTimer.endOwnership(restoring: previousOwner)
                case .relaxRound:
                    // Perturbing away from a counterexample an earlier action just improved spends budget escaping a local minimum the run may not be in.
                    guard anyAccepted == false else {
                        continue
                    }
                    let previousOwner = stepTimer.beginOwnership(.relaxRound)
                    if runRelaxRound() {
                        recordPostCycleAcceptance()
                    }
                    stepTimer.endOwnership(restoring: previousOwner)
            }
        }
        return .completed
    }

    /// Records an acceptance made by a post-cycle action: marks the cycle accepted and restores the stall budget.
    ///
    /// The stall that scheduled the action has already been spent, and the relax round runs only on the stall that would end the run. Without fresh budget the run could stop before ordinary reduction, bind search included, reaches the accepted counterexample.
    mutating func recordPostCycleAcceptance() {
        anyAccepted = true
        anyAcceptanceEverOccurred = true
        stallBudget = maxStalls
    }

    /// Records an acceptance whose effect can reach beyond the edited leaves, because the property couples values the generator treats as independent. Every convergence floor, cached rejection, and bind search history is invalidated as well.
    mutating func invalidateAfterCoupledAcceptance() {
        recordPostCycleAcceptance()
        graph.convergenceStore.removeAll()
        rejectCache.removeAll()
        gate.invalidateSearchHistory()
    }

    /// Applies a post-cycle pass's policy and, for an acceptance that needs one, a graph-only rebuild. Post-cycle actions never rebuild sources.
    mutating func applyPostCycleReport(_ pass: PassRecord, appliedPasses: Int = 1) {
        applyPassPolicy(pass, appliedPasses: appliedPasses)
        if pass.requiresRebuild {
            rebuildGraph(after: pass)
        }
    }

    // MARK: - Convergence Confirmation

    /// Probes each converged leaf one step past its floor towards its reduction target to find stale floors, then two steps when that rejects and the target is that far away, for non-monotone gaps. A passing probe clears the record so minimization can work on the leaf again.
    ///
    /// A leaf below its target in bit-pattern space, such as a negative signed integer, steps upward. Stepping down from it would move away from the target, which shortlex ordering skips without a probe.
    ///
    /// - Returns: Whether any stale floor was cleared.
    @discardableResult
    mutating func confirmConvergence() -> Bool {
        var anyStale = false
        var counts = ReductionProbeCounts()
        defer {
            stats.record(counts, for: .convergenceConfirmation)
        }

        let selection: ReductionDecoder.Selection = hasBind
            ? .guided(materializePicks: false)
            : .exact(materializePicks: false, admission: .standard)

        for nodeID in graph.leafNodes {
            if deadline.isExpired {
                break
            }
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
                continue
            }
            guard let origin = graph.convergenceStore[nodeID] else {
                continue
            }
            guard let range = graph.nodes[nodeID].positionRange else {
                continue
            }

            let target = metadata.value.reductionTarget(in: metadata.validRange)
            guard origin.bound != target else {
                continue
            }

            let nearerBitPattern = Self.bitPattern(origin.bound, steppedTowards: target, by: 1)
            let result = probeCloser(
                value: nearerBitPattern,
                at: range.lowerBound,
                selection: selection,
                counts: &counts
            )

            if result == .accepted {
                anyStale = true
                graph.clearConvergence(nodeID)
                ReductionLog.reducer("stale_convergence_detected", isInstrumented: isInstrumented, metadata: [
                    "position": "\(range.lowerBound)", "old_floor": "\(origin.bound)", "probe_succeeded_at": "\(nearerBitPattern)",
                ])
            } else if result == .rejected, origin.bound.absoluteDifference(target) >= 2, deadline.isExpired == false {
                let gapBitPattern = Self.bitPattern(origin.bound, steppedTowards: target, by: 2)
                let gapResult = probeCloser(
                    value: gapBitPattern,
                    at: range.lowerBound,
                    selection: selection,
                    counts: &counts
                )
                if gapResult == .accepted {
                    anyStale = true
                    graph.clearConvergence(nodeID)
                    ReductionLog.reducer("non_monotone_convergence_detected", isInstrumented: isInstrumented, metadata: [
                        "position": "\(range.lowerBound)", "floor": "\(origin.bound)", "gap_probe_succeeded_at": "\(gapBitPattern)",
                    ])
                }
            }
        }

        return anyStale
    }

    private enum ConfirmationProbeResult {
        case accepted
        case rejected
        case skipped
    }

    /// The bit pattern `step` past `bound` in the direction of `target`.
    private static func bitPattern(_ bound: UInt64, steppedTowards target: UInt64, by step: UInt64) -> UInt64 {
        switch bound > target {
            case true:
                bound - step
            case false:
                bound + step
        }
    }

    /// Decodes the sequence with one value moved closer to its target, without committing it: a failing decode only proves the floor stale.
    private mutating func probeCloser(
        value: UInt64,
        at sequenceIndex: Int,
        selection: ReductionDecoder.Selection,
        counts: inout ReductionProbeCounts
    ) -> ConfirmationProbeResult {
        var candidate = incumbent.sequence
        candidate[sequenceIndex] = candidate[sequenceIndex].withBitPattern(value)
        guard candidate.shortLexPrecedes(incumbent.sequence) else {
            return .skipped
        }

        counts.recordEmission()

        let probeHash = ZobristHash.incrementalHash(
            baseHash: incumbentHash,
            baseSequence: incumbent.sequence,
            probe: candidate
        )
        let cacheKey = rejectCache.key(
            probeHash: probeHash,
            decision: ProbeDecision(selection),
            incumbentHash: incumbentHash
        )
        let evaluation = CandidateEvaluator.evaluate(
            candidate,
            against: incumbent,
            using: selection,
            decoder: decoder,
            admits: { _ in true },
            probeHash: probeHash,
            cacheHit: rejectCache.contains(cacheKey),
            cacheKey: cacheKey,
            cache: &rejectCache,
            counts: &counts
        )
        switch evaluation {
            case .cached:
                return .skipped
            case .rejected:
                return .rejected
            case .admitted:
                counts.recordAcceptance()
                return .accepted
        }
    }

    // MARK: - Relation Pass

    /// Runs relation search once value search has written its stall evidence.
    private mutating func runRelationPass() {
        guard let scope = RelationQuery.build(graph: graph) else {
            return
        }
        guard deadline.isExpired == false else {
            stats.reductionWasCapped = true
            return
        }
        let pass = runPass(.relation(scope), boundValueFingerprint: nil, usesWarmStarts: false)
        applyPostCycleReport(pass)
        if isInstrumented, pass.report.anyAccepted {
            ExhaustLog.notice(category: .reducer, event: "graph_relation_pass_accepted")
        }
    }

    // MARK: - Staged Joint Pass

    /// Whether a staged joint checkpoint differs from the one last searched, with sampled or sign-flip-only pairs to search.
    func hasPendingStagedJointCheckpoint() -> Bool {
        guard isEncoderEnabled(.stagedJointSearch) else {
            return false
        }
        let source = stagedJointSource()
        return source.dispatchPriority != nil
    }

    /// Searches the pending checkpoint, marking it searched before the encoder's reduction starts so a deadline interruption does not repeat it. An acceptance invalidates every floor, cached rejection, and bind search history, because the property couples the moved values.
    private mutating func runStagedJointPass() {
        guard deadline.isExpired == false else {
            return
        }
        let source = stagedJointSource()
        guard let priced = source.nextScope(), case let .stagedJoint(scope) = priced.encoderScope else {
            return
        }
        exhaustedStagedJoint = StagedJointSource.Checkpoint(base: incumbent.sequence, scope: scope)
        let pass = runPass(.stagedJoint(scope), boundValueFingerprint: nil, usesWarmStarts: false)
        applyPostCycleReport(pass, appliedPasses: max(1, pass.report.searchCounts.count))
        if pass.report.anyAccepted {
            invalidateAfterCoupledAcceptance()
        }
    }

    private func stagedJointSource() -> StagedJointSource {
        StagedJointSource(
            graph: graph,
            sequence: incumbent.sequence,
            isFruitlessBind: gate.isFruitless,
            exhausted: exhaustedStagedJoint,
            tuning: tuning
        )
    }

    // MARK: - Improving Pivots

    /// Whether the improving pivot phase has a probe to spend.
    var hasUnprobedImprovingPivot: Bool {
        guard isEncoderEnabled(.branchPivot), tuning.relaxImprovingProbeBudget > 0 else {
            return false
        }
        var cursor = ImprovingPivotCursor(sequence: incumbent.sequence, incumbentHash: incumbentHash, graph: graph, rejectCache: rejectCache, deadline: deadline)
        return cursor.next() != nil
    }

    /// Probes improving pivots at non-minimal content and accepts the first that still fails the property, without a checkpoint, because every accepted probe already precedes the sequence. The next cycle minimizes the accepted arm under ordinary scheduling.
    ///
    /// - Returns: Whether a pivot was accepted.
    mutating func runImprovingPivotPass() -> Bool {
        let budget = tuning.relaxImprovingProbeBudget
        guard budget > 0 else {
            return false
        }
        var probesUsed = 0
        var probeCounts = ReductionProbeCounts()
        defer {
            stats.recordStructuralRelax(probeCounts)
            if collectStats {
                stats.relaxImprovingProbes += probesUsed
            }
        }
        var candidates = ImprovingPivotCursor(sequence: incumbent.sequence, incumbentHash: incumbentHash, graph: graph, rejectCache: rejectCache, deadline: deadline)
        while probesUsed < budget {
            guard let probe = candidates.next(), deadline.isExpired == false else {
                break
            }
            let candidate = probe.sequence
            probesUsed += 1
            probeCounts.recordEmission()
            // The cursor checked its cache snapshot and suppresses every probe it has returned since.
            guard case let .admitted(recovered, _) = CandidateEvaluator.evaluate(
                candidate,
                against: incumbent,
                using: .exact(materializePicks: true, admission: .standard),
                decoder: decoder,
                admits: { [baseline = incumbent.sequence] in $0.sequence.shortLexPrecedes(baseline) },
                probeHash: probe.probeHash,
                cacheHit: false,
                cacheKey: probe.cacheKey,
                cache: &rejectCache,
                counts: &probeCounts
            ) else {
                continue
            }
            probeCounts.recordAcceptance()
            incumbent = recovered
            if collectStats {
                stats.relaxImprovingAcceptances += 1
            }
            rebuildAndUpdateGraph()
            ReductionLog.reducer("relax_round_improving_pivot_accepted", isInstrumented: isInstrumented, metadata: [
                "seq_len": "\(incumbent.sequence.count)", "probes": "\(probesUsed)",
            ])
            return true
        }
        return false
    }
}
