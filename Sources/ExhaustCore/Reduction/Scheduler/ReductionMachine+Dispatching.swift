//
//  ReductionMachine+Dispatching.swift
//  Exhaust
//

// MARK: - Dispatching Sub-Phases

extension ReductionMachine {
    /// Lends core state to the main dispatch loop without retaining an array copy across its source mutations.
    mutating func stepDispatching() -> Transition {
        var loop = dispatchLoop
        dispatchLoop = DispatchLoop(policy: .main)
        let transition = loop.step(state: &self)
        dispatchLoop = loop
        guard let transition else {
            preconditionFailure("The main dispatch loop must report its final source exhaustion")
        }
        return transition
    }

    // MARK: - Apply Pass Policy

    /// Applies post-pass policy from a completed encoder pass.
    ///
    /// Shared by dispatched and post-cycle passes. Records convergence, gate outcomes, scope rejections, statistics, and acceptance flags without changing the caller's dispatch phase or pending report. The returned action lets each caller choose its own rebuild and routing behavior.
    mutating func applyPassPolicy(_ report: PassReport) -> ChoiceGraphScheduler.PostAcceptanceAction {
        passCounter += 1
        var valueMotionNodes: Set<Int> = []

        if report.convergenceRecords.isEmpty == false {
            let motion = graph.recordConvergence(
                byNodeID: report.convergenceRecords,
                rebuildGeneration: stats.graphStats.fullGraphRebuilds
            )
            valueMotionNodes = motion.valueMotionNodeIDs
            if collectDiagnostics {
                for motionNodeID in motion.valueMotionNodeIDs {
                    let sincePass = lastConvergencePass[motionNodeID] ?? 0
                    var partnerNodes: Set<Int> = []
                    for entry in valueChangeLog where entry.passIndex > sincePass {
                        for changedNodeID in entry.nodeIDs where changedNodeID != motionNodeID {
                            partnerNodes.insert(changedNodeID)
                            let edge = CouplingEdge(motionNodeID: motionNodeID, changedNodeID: changedNodeID)
                            stats.couplingEdges[edge, default: 0] += 1
                        }
                    }
                    stats.floorMotionPartnerCounts[partnerNodes.count, default: 0] += 1
                }

                stats.structuralFloorMotionEvents += motion.structural
                stats.valueFloorMotionEvents += motion.value
                stats.valueFloorMotionNodeIDs.formUnion(motion.valueMotionNodeIDs)

                for nodeID in report.convergenceRecords.keys {
                    lastConvergencePass[nodeID] = passCounter
                }
            }
        }

        if isEncoderEnabled(.stagedJointSearch), tuning.stagedJointProbeBudget > 0 {
            couplingTracker.observe(
                motionNodes: valueMotionNodes,
                convergedNodes: Array(report.convergenceRecords.keys),
                changedNodes: report.acceptedLeafNodeIDs,
                pass: passCounter,
                graph: &graph
            )
        }

        if collectDiagnostics, report.acceptedLeafNodeIDs.isEmpty == false {
            valueChangeLog.append((passIndex: passCounter, nodeIDs: report.acceptedLeafNodeIDs))
        }

        if let fingerprint = report.boundValueFingerprint {
            convergence.gate.recordOutcome(fingerprint: fingerprint, accepted: report.anyAccepted)
        }

        if report.encoderName == .migration {
            migrationConsecutiveRejects = report.anyAccepted ? 0 : migrationConsecutiveRejects + 1
        }

        if hadUnresolvedReplacement == false,
           report.hadUnresolvedReplacement
        {
            hadUnresolvedReplacement = true
        }

        if collectStats {
            stats.record(report.counts, for: report.encoderName)
            switch report.transformation.operation {
                case .exchange(.stagedNumericPairs):
                    stats.numericSearchCountsByArity[2, default: .init()].merge(report.counts)
                case let .exchange(.numericJoint(groups, _)):
                    if let arity = groups.first?.leaves.count {
                        stats.numericSearchCountsByArity[arity, default: .init()].merge(report.counts)
                    }
                default:
                    break
            }
            if let liftMaterializations = report.liftMaterializations {
                stats.recordMaterializations(liftMaterializations.count, at: liftMaterializations.site)
            }
        }

        if collectDiagnostics {
            let distanceDelta = dispatchBaselineTargetDistance - sequenceTargetDistance()
            stats.dispatchLog.append(DispatchRecord(
                cycle: cycles,
                passIndex: passCounter,
                encoderName: report.encoderName,
                probeCount: report.probeCount,
                acceptCount: report.acceptCount,
                cacheHitCount: report.cacheHitCount,
                decoderRejectCount: report.decoderRejectCount,
                sequenceLengthDelta: dispatchBaselineLength - sequence.count,
                targetDistanceDelta: distanceDelta,
                boundValueFingerprint: report.boundValueFingerprint,
                composedUpstreamLifts: report.composedUpstreamLifts,
                bindClassification: report.boundValueFingerprint.flatMap { graph.bindClassifications[$0] }
            ))

            if report.anyAccepted,
               case .exchange(.redistribution) = report.transformation.operation
            {
                stats.redistributionAcceptanceNodeIDs.formUnion(report.acceptedLeafNodeIDs)
            }
        }

        ChoiceGraphScheduler.logReducer("graph_encoder_pass", isInstrumented: isInstrumented, metadata: [
            "encoder": report.encoderName.rawValue, "probes": "\(report.probeCount)",
            "accepted": "\(report.acceptCount)", "cache_hits": "\(report.cacheHitCount)",
            "decoder_rejects": "\(report.decoderRejectCount)", "seq_len": "\(sequence.count)",
        ])

        let probeOutcome = ChoiceGraphScheduler.ProbeLoopOutcome(
            accepted: report.anyAccepted,
            requiresRebuild: report.anyRequiresRebuild,
            treeIsStripped: report.latestTreeIsStripped
        )

        let acceptanceAction = ChoiceGraphScheduler.evaluateAcceptance(
            outcome: probeOutcome,
            operation: report.transformation.operation
        )

        if report.anyAccepted {
            anyAccepted = true
            anyAcceptanceEverOccurred = true
        }

        switch acceptanceAction {
            case .continueDispatching:
                if report.anyAccepted == false {
                    scopeRejectionCache.recordRejection(
                        operation: report.transformation.operation,
                        sequence: sequence,
                        graph: graph
                    )
                }
            case .rebuildAndResume:
                convergence.gate.clearFruitless()
        }
        return acceptanceAction
    }

    /// Restores the unselected branches of a stripped tree and rebuilds the graph, so pick nodes carry every arm.
    ///
    /// - Returns: The graph before the rebuild.
    @discardableResult
    mutating func rematerializeUnselectedBranches() -> ChoiceGraph {
        if collectStats {
            stats.recordMaterializations(1, at: .rematerialization)
        }
        if case let .success(_, fullTree, _) = Materializer.materializeAny(
            gen,
            context: .init(
                prefix: sequence,
                mode: .exact,
                fallbackTree: tree,
                materializePicks: true
            )
        ) {
            tree = fullTree
        }
        let graphBefore = graph
        _ = rebuildAndUpdateGraph()
        graphIsStripped = false
        return graphBefore
    }
}
