//
//  ReductionMachine+PostCycleEncoders.swift
//  Exhaust
//

// MARK: - Post-Cycle Encoder Passes

extension ReductionMachine {
    /// Runs the relation encoder over stall-converged leaf pairs, returning true when any probe was accepted.
    ///
    /// Runs as a post-cycle action rather than a dispatched source because the stall gate depends on convergence records that value search writes mid-cycle: a workload that stalls in its first cycle terminates before any source rebuild could observe them. An acceptance sets `anyAccepted` through ``applyPassReport(_:)``, so the termination check re-enters the cycle loop and value search re-certifies the moved leaves.
    mutating func runRelationPass() throws -> Bool {
        if let enabled = enabledEncoders, enabled.contains(.relationSearch) == false {
            return false
        }
        guard let relationScope = RelationQuery.build(graph: graph) else {
            return false
        }
        let report = try runPostCycleEncoder(
            operation: .exchange(.relation(relationScope)),
            estimatedCost: relationScope.pairs.count * 8
        )
        if isInstrumented, report.anyAccepted {
            ExhaustLog.notice(category: .reducer, event: "graph_relation_pass_accepted")
        }
        return report.anyAccepted
    }

    /// Runs one encoder pass to completion outside cycle dispatch, through the same decoding, accounting, and acceptance policy as dispatched passes.
    ///
    /// A reshaping acceptance rebuilds the graph here rather than through the dispatch rebuild phase, which never runs between post-cycle actions: later actions and the next cycle's source build read the live graph.
    mutating func runPostCycleEncoder(
        operation: GraphOperation,
        estimatedCost: Int,
        deadlineCheck: (() -> Bool)? = nil
    ) throws -> PassReport {
        let transformation = GraphTransformation(
            operation: operation,
            priority: DispatchPriority(
                structuralBenefit: 0,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: estimatedCost
            )
        )
        var encoder = ChoiceGraphScheduler.selectEncoder(for: operation, gen: gen)
        encoder.start(scope: EncoderInput(
            transformation: transformation,
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        ))

        let hasBind = sequence.contains { entry in
            if case .bind = entry { return true }
            return false
        }
        captureDispatchBaseline()
        var session = ProbeSession(
            encoder: encoder,
            transformation: transformation,
            boundValueFingerprint: nil,
            baseSequence: sequence,
            hasBind: hasBind
        )
        let report = try session.runToCompletion(state: &self, deadlineCheck: deadlineCheck)

        _ = applyPassReport(report)

        if report.anyAccepted, report.anyRequiresRebuild {
            _ = rebuildAndUpdateGraph(
                valueGuardExemptNodeIDs: report.acceptedLeafNodeIDs
                    .union(report.convergenceRecords.keys)
            )
            graphIsStripped = report.latestTreeIsStripped
        }
        return report
    }
}
