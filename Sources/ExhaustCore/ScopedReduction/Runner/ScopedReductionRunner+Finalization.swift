//
//  ScopedReductionRunner+Finalization.swift
//  Exhaust
//

// MARK: - Finalization

extension ScopedReductionRunner {
    /// Reorders sibling groups numerically for presentation, with an empty rejection cache that is restored afterwards. Runs to completion even past the deadline, so the returned counterexample is always presented the same way.
    ///
    /// - Returns: Whether a reordering was accepted.
    mutating func runReorderPass() -> Bool {
        let previousOwner = beginTimingOwnership(.reorder)
        defer {
            endTimingOwnership(restoring: previousOwner)
        }
        guard isEncoderEnabled(.numericReorder),
              var source = ScopedSource.prepareReorderSource(from: graph, tuning: tuning),
              let priced = source.nextScope()
        else {
            return false
        }
        let savedRejectCache = rejectCache
        rejectCache = []
        let pass = runPass(priced.opportunity, boundValueFingerprint: nil, usesWarmStarts: false, checksDeadline: false)
        rejectCache = savedRejectCache
        applyPassPolicy(pass)
        if isInstrumented, pass.report.anyAccepted {
            ExhaustLog.notice(category: .reducer, event: "graph_human_order_accepted")
        }
        return pass.report.anyAccepted
    }

    /// Records the stall diagnostics once the reorder pass has applied.
    mutating func completeReorderPass(accepted _: Bool) {
        recordStallDiagnostic()
    }

    /// Ends a run whose deadline passed: any in-flight pass has already applied its report, so only the final reorder and the stall diagnostics remain.
    mutating func finishAtDeadline() {
        stats.reductionWasCapped = true
        sources = []
        let accepted = isEncoderEnabled(.numericReorder) ? runReorderPass() : false
        completeReorderPass(accepted: accepted)
    }

    // MARK: - Helpers

    /// Counts leaves that ended short of their target with a convergence floor at their current value: the encoder proved they cannot move alone. Normal at the end of a successful run, so the warning sign is a nonzero count on a run where ``anyAcceptanceEverOccurred`` is still false. Depth, lane, and bind-inner leaves are machinery rather than user values, and are excluded.
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
}
