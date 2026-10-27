//
//  ReductionSession+PostCycle.swift
//  Exhaust
//

// MARK: - Post-Cycle Actions

extension ReductionSession {
    /// A candidate still needs adoption and a graph rebuild; a committed result already has both. Extra invalidation travels with the result so the common transition applies it.
    enum PostCycleResult {
        case unchanged
        case recovered(Counterexample, isTreeStripped: Bool)
        case committed(invalidating: PostCycleInvalidations)
    }

    /// Invalidates evidence beyond the fruitless verdicts cleared by every acceptance.
    struct PostCycleInvalidations: OptionSet {
        let rawValue: UInt8

        /// Drops floors whose validity may depend on the jointly changed values.
        static let convergence = Self(rawValue: 1 << 0)
        /// Restores bind budgets after escaping a coupled stall.
        static let searchHistory = Self(rawValue: 1 << 1)
    }

    /// Runs the scheduled actions in order against the current graph, stopping at the deadline. A prior acceptance skips relaxation because the improved counterexample has not yet stalled.
    mutating func runPostCycleActions(_ actions: [PostCycleAction]) -> PhaseOutcome {
        for action in actions {
            guard deadline.isExpired == false else {
                return .deadline
            }
            // Perturbing an improvement would spend escape budget before ordinary reduction has searched it.
            if action == .relaxRound, anyAccepted {
                continue
            }
            runPostCycleAction(action)
        }
        return .completed
    }

    /// Keeps decoding, adoption, graph rebuilding, and invalidation in the recovering action's timing bucket, including nested pass charges.
    private mutating func runPostCycleAction(_ action: PostCycleAction) {
        let previousOwner = stepTimer.beginOwnership(action.timingBucket)
        defer {
            stepTimer.endOwnership(restoring: previousOwner)
        }
        let result: PostCycleResult = switch action {
            case .confirmConvergence:
                confirmConvergence()
            case .relationPass:
                runRelationPass()
            case .improvingPivots:
                runImprovingPivotPass()
            case .stagedJointPass:
                runStagedJointPass()
            case .relaxRound:
                runRelaxRound() ? .committed(invalidating: []) : .unchanged
        }
        applyPostCycleResult(result)
    }

    /// Adopts a recovered witness even when its property call expired the deadline, and renews the budget for ordinary reduction. Applies only the additional invalidation reported by the accepting action; cache entries retain their decision and incumbent keys.
    private mutating func applyPostCycleResult(_ result: PostCycleResult) {
        let invalidations: PostCycleInvalidations
        switch result {
            case .unchanged:
                return
            case let .recovered(counterexample, isTreeStripped):
                incumbent = counterexample
                rebuildAndUpdateGraph()
                graphIsStripped = isTreeStripped
                invalidations = []
            case let .committed(invalidating):
                invalidations = invalidating
        }
        markProgress()
        stallBudget = maxStalls
        if invalidations.contains(.convergence) {
            graph.convergenceStore.removeAll()
        }
        if invalidations.contains(.searchHistory) {
            gate.invalidateSearchHistory()
        }
    }

    /// Applies a post-cycle pass's accounting and graph changes. Further invalidation is carried by the action result and applied by the common transition.
    mutating func applyPostCycleReport(_ pass: PassRecord, appliedPasses: Int = 1) {
        applyPassPolicy(pass, appliedPasses: appliedPasses)
        if pass.requiresRebuild {
            rebuildGraph(after: pass)
        }
    }

    // MARK: - Relation Pass

    /// Runs relation search once value search has written its stall evidence.
    private mutating func runRelationPass() -> PostCycleResult {
        guard let scope = RelationQuery.build(graph: graph) else {
            return .unchanged
        }
        guard deadline.isExpired == false else {
            stats.reductionWasCapped = true
            return .unchanged
        }
        let pass = runPass(.relation(scope), boundValueFingerprint: nil, usesWarmStarts: false)
        applyPostCycleReport(pass)
        if isInstrumented, pass.report.anyAccepted {
            ExhaustLog.notice(category: .reducer, event: "graph_relation_pass_accepted")
        }
        // Moving a related pair can lower a third leaf's floor even when that leaf's value has not changed.
        return pass.report.anyAccepted ? .committed(invalidating: [.convergence]) : .unchanged
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

    /// Searches the pending checkpoint, marking it searched before the encoder's reduction starts so a deadline interruption does not repeat it. An acceptance invalidates every floor and restores bind search budgets because the joint search escaped a coupled stall. Cached decisions remain reusable under their existing keys.
    private mutating func runStagedJointPass() -> PostCycleResult {
        guard deadline.isExpired == false else {
            return .unchanged
        }
        let source = stagedJointSource()
        guard let priced = source.nextScope(), case let .stagedJoint(scope) = priced.encoderScope else {
            return .unchanged
        }
        exhaustedStagedJoint = StagedJointSource.Checkpoint(base: incumbent.sequence, scope: scope)
        let pass = runPass(.stagedJoint(scope), boundValueFingerprint: nil, usesWarmStarts: false)
        applyPostCycleReport(pass, appliedPasses: max(1, pass.report.searchCounts.count))
        return pass.report.anyAccepted ? .committed(invalidating: [.convergence, .searchHistory]) : .unchanged
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
    /// - Returns: The recovered failure, for the common post-cycle transition to adopt.
    mutating func runImprovingPivotPass() -> PostCycleResult {
        let budget = tuning.relaxImprovingProbeBudget
        guard budget > 0 else {
            return .unchanged
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
                admits: { [incumbent] in incumbent.admits($0, under: .strictlySmaller) },
                lookup: probe.lookup,
                cache: &rejectCache,
                counts: &probeCounts
            ) else {
                continue
            }
            probeCounts.recordAcceptance()
            if collectStats {
                stats.relaxImprovingAcceptances += 1
            }
            ReductionLog.reducer("relax_round_improving_pivot_accepted", isInstrumented: isInstrumented, metadata: [
                "seq_len": "\(recovered.sequence.count)",
                "probes": "\(probesUsed)",
            ])
            return .recovered(recovered, isTreeStripped: false)
        }
        return .unchanged
    }
}
