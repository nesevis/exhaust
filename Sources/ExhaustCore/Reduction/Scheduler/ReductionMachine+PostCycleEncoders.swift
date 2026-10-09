//
//  ReductionMachine+PostCycleEncoders.swift
//  Exhaust
//

// MARK: - Post-Cycle Encoder Passes

extension ReductionMachine {
    /// Starts relation search after value search has written its stall evidence, retaining the remaining actions until the pass completes.
    mutating func startRelationPass(remaining: [ChoiceGraphScheduler.PostCycleAction]) -> Transition {
        guard isEncoderEnabled(.relationSearch),
              let scope = RelationQuery.build(graph: graph),
              let session = makePostCycleSession(
                  operation: .exchange(.relation(scope)),
                  estimatedCost: scope.pairs.count * 8
              )
        else {
            return .relationPassCompleted(accepted: false)
        }
        phase = .postCycleProbing(PostCycleFrame(session: session, pass: .relation, remaining: remaining))
        return .postCycleStarted(owner: .relationPass)
    }

    /// Restores the action queue only after the in-flight pass has finished applying its report.
    mutating func resumePostCycle(remaining: [ChoiceGraphScheduler.PostCycleAction]) {
        phase = remaining.isEmpty ? .checkTermination : .postCycle(remaining: remaining)
    }

    /// Starts a fresh post-cycle encoder with no warm starts, preserving the enabled-encoder and deadline guards.
    mutating func makePostCycleSession(operation: GraphOperation, estimatedCost: Int) -> ProbeSession? {
        guard isEncoderEnabled(operation.encoderName) else {
            return nil
        }
        guard isDeadlineExceeded() == false else {
            stats.reductionWasCapped = true
            return nil
        }
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
        captureDispatchBaseline()
        return ProbeSession(
            encoder: encoder,
            transformation: transformation,
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

    /// Applies shared policy and a graph-only rebuild; post-cycle actions never rebuild candidate sources.
    mutating func applyPostCycleReport(_ report: PassReport) {
        _ = applyPassPolicy(report)
        if report.anyAccepted, report.anyRequiresRebuild {
            _ = rebuildAndUpdateGraph(
                valueGuardExemptNodeIDs: report.acceptedLeafNodeIDs.union(report.convergenceRecords.keys)
            )
            graphIsStripped = report.latestTreeIsStripped
        }
    }

    /// Applies relation policy and preserves its acceptance event on normal completion and deadline interruption.
    mutating func finishRelationReport(_ report: PassReport) {
        applyPostCycleReport(report)
        if isInstrumented, report.anyAccepted {
            ExhaustLog.notice(category: .reducer, event: "graph_relation_pass_accepted")
        }
    }

    /// Restores search rejections before applying cosmetic reorder policy, which does not rebuild the graph.
    mutating func finishReorderReport(_ report: PassReport, savedRejectCache: Set<UInt64>) {
        rejectCache = savedRejectCache
        _ = applyPassPolicy(report)
        if isInstrumented, report.anyAccepted {
            ExhaustLog.notice(category: .reducer, event: "graph_human_order_accepted")
        }
    }
}
