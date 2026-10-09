extension ReductionMachine {
    // MARK: - Reorder Pass

    /// Starts final presentation work with the rejection cache retained by its post-cycle frame.
    mutating func stepReorderPass() -> Transition {
        guard isEncoderEnabled(.numericReorder), let session = makeReorderSession() else {
            return completeReorderPass(accepted: false)
        }
        let savedRejectCache = rejectCache
        rejectCache = []
        captureDispatchBaseline()
        phase = .postCycleProbing(PostCycleFrame(session: session, pass: .reorder(savedRejectCache: savedRejectCache), remaining: []))
        return .postCycleStarted(owner: .reorder)
    }

    /// Finalizes diagnostics after the reorder session has applied its report and restored the rejection cache.
    mutating func completeReorderPass(accepted: Bool) -> Transition {
        recordStallDiagnostic()
        phase = .done
        return .reorderCompleted(accepted: accepted)
    }

    /// Populates the stall-diagnostic fields on ``ReductionStats`` at termination.
    ///
    /// A leaf is stalled when it holds a convergence record whose bound equals its current bit pattern while that pattern differs from the reduction target: the encoder proved the leaf cannot move alone, and it did not reach its target. Leaf counts use the graph from before final numeric reordering, which does not update the graph; the acceptance flag includes that final pass. Stalled leaves are normal at the end of a successful reduction (a property demanding nonzero values leaves every surviving leaf short of its target), so the count alone is not a warning signal — the warning condition is a nonzero count on a run where ``anyAcceptanceEverOccurred`` is still false. Control-scope leaves (depth, lane, bind-inner) are machinery, not user values, and are excluded.
    private mutating func recordStallDiagnostic() {
        var stalledCount = 0
        var residualDistance: Double = 0
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else {
                continue
            }
            let annotation = node.scopeAnnotation
            if annotation.isDepthControl || annotation.isLaneControl || annotation.isBindInner {
                continue
            }
            let bitPattern = metadata.value.bitPattern64
            let target = metadata.value.reductionTarget(in: metadata.validRange)
            guard bitPattern != target else {
                continue
            }
            guard let record = graph.convergenceStore[nodeID], record.bound == bitPattern else {
                continue
            }
            stalledCount += 1
            residualDistance += Double(bitPattern > target ? bitPattern - target : target - bitPattern)
        }
        stats.stalledLeafCount = stalledCount
        stats.stalledLeafResidualDistance = residualDistance
        stats.anyAcceptanceEverOccurred = anyAcceptanceEverOccurred
    }

    // MARK: - Deadline Finalization

    /// Applies an interrupted search session exactly once, then runs the enabled final numeric reorder pass without rebuilding candidate sources.
    ///
    /// A pending structural acceptance rebuilds only the graph needed for final reordering and stall diagnostics. The decoded sequence, tree, and output are already committed; cosmetic reordering never needs a graph rebuild after its final value is accepted.
    mutating func finishAtDeadline() -> Transition {
        stats.reductionWasCapped = true
        if case .done = phase {
            return .terminated
        }
        if var frame = excursionFrame {
            excursionFrame = nil
            if frame.finishAtDeadline(state: &self) {
                recordPostCycleAcceptance()
            }
        }
        if case let .postCycleProbing(frame) = phase {
            _ = frame.complete(state: &self, reason: .deadline)
            if case .done = phase {
                pendingReport = nil
                sources = []
                return .terminated
            }
        }
        if let session = activeSession {
            let report = session.report()
            activeSession = nil
            pendingReport = report
            _ = applyPassPolicy(report)
        }
        if let report = pendingReport, report.anyAccepted, report.anyRequiresRebuild {
            _ = rebuildAndUpdateGraph(
                valueGuardExemptNodeIDs: report.acceptedLeafNodeIDs.union(report.convergenceRecords.keys)
            )
            graphIsStripped = report.latestTreeIsStripped
        }
        pendingReport = nil
        sources = []
        let accepted = isEncoderEnabled(.numericReorder) ? runReorderPass() : false
        _ = completeReorderPass(accepted: accepted)
        return .terminated
    }

    /// Builds final reordering work without a deadline gate: an expired search must still finish its presentation pass.
    func makeReorderSession() -> ProbeSession? {
        guard let reorderScope = ReorderingQuery.build(graph: graph) else {
            return nil
        }
        let reorderTransformation = GraphTransformation(
            operation: .reorder(reorderScope),
            priority: DispatchPriority(structuralBenefit: 0, valueBenefit: 0, reductionMagnitude: 0, estimatedCost: 1)
        )
        let scope = EncoderInput(
            transformation: reorderTransformation,
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        )
        var encoder: EncoderDispatch = .init(GraphReorderEncoder())
        encoder.start(scope: scope)

        return ProbeSession(
            encoder: encoder,
            transformation: reorderTransformation,
            boundValueFingerprint: nil,
            baseSequence: sequence,
            hasBind: sequence.contains { entry in
                if case .bind = entry {
                    return true
                }
                return false
            }
        )
    }

    /// Runs final presentation work synchronously when the search deadline has already expired.
    private mutating func runReorderPass() -> Bool {
        guard let session = makeReorderSession() else {
            return false
        }
        let savedRejectCache = rejectCache
        rejectCache = []
        captureDispatchBaseline()
        let report = session.runToCompletion(state: &self)
        finishReorderReport(report, savedRejectCache: savedRejectCache)
        return report.anyAccepted
    }
}
