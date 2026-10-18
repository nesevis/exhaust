//
//  ScopedReductionRunner+Finalization.swift
//  Exhaust
//

// MARK: - Finalization

extension ScopedReductionRunner {
    /// Reorders sibling groups numerically for presentation, with an empty rejection cache that is restored afterwards. Runs to completion even past the deadline, so the returned counterexample is always presented the same way.
    ///
    /// An accepted reordering rebuilds the graph, which ends its pass, so the groups are discovered again on the rebuilt graph and the next unsorted group gets its own pass. Each accepted pass sorts at least one group, so the first discovery's group count bounds the passes. The rejection cache is kept across these passes, so a group the property refused is not probed again while the sequence around it is unchanged.
    mutating func runReorderPass() {
        let previousOwner = beginTimingOwnership(.reorder)
        defer {
            endTimingOwnership(restoring: previousOwner)
        }
        guard isEncoderEnabled(.numericReorder),
              let source = ScopedSource.prepareReorderSource(from: graph),
              var priced = source.nextScope(),
              case let .reorder(firstScope) = priced.encoderScope
        else {
            return
        }
        let savedRejectCache = rejectCache
        rejectCache = rejectCache.emptied
        defer {
            rejectCache = savedRejectCache
        }
        var passesRemaining = firstScope.groups.count
        while true {
            let pass = runPass(priced.encoderScope, boundValueFingerprint: nil, usesWarmStarts: false, checksDeadline: false)
            let action = applyPassPolicy(pass)
            if isInstrumented, pass.report.anyAccepted {
                ExhaustLog.notice(category: .reducer, event: "graph_human_order_accepted")
            }
            guard action == .rebuildAndResume else {
                return
            }
            rebuildAndUpdateGraph(valueGuardExemptNodeIDs: Self.valueGuardExemptNodeIDs(of: pass))
            graphIsStripped = pass.report.latestTreeIsStripped
            passesRemaining -= 1
            guard passesRemaining > 0,
                  let nextSource = ScopedSource.prepareReorderSource(from: graph),
                  let nextPriced = nextSource.nextScope()
            else {
                return
            }
            priced = nextPriced
        }
    }

    /// Ends a run whose deadline passed: any in-flight pass has already applied its report, so only the final reorder and the stall diagnostics remain.
    mutating func finishAtDeadline() {
        stats.reductionWasCapped = true
        sources = []
        runReorderPass()
        recordStallDiagnostic()
    }

    /// Counts leaves that ended short of their target with a convergence floor at their current value: the encoder proved they cannot move alone. Normal at the end of a successful run, so the warning sign is a nonzero count on a run where ``anyAcceptanceEverOccurred`` is still false. Depth, lane, and bind-inner leaves are machinery rather than user values, and are excluded.
    mutating func recordStallDiagnostic() {
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
            residualDistance += Double(bitPattern.absoluteDifference(target))
        }
        stats.stalledLeafCount = stalledCount
        stats.stalledLeafResidualDistance = residualDistance
        stats.anyAcceptanceEverOccurred = anyAcceptanceEverOccurred
    }
}
