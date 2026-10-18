//
//  ReductionSession+Diagnostics.swift
//  Exhaust
//

// MARK: - Research Diagnostics

extension ReductionSession {
    /// Floor-motion counters, coupling attribution, and the per-dispatch log, recorded into the run's statistics only when enabled.
    struct ResearchDiagnostics {
        /// A maintainer-set literal rather than configuration, because these per-pass costs must not ride `collectStats`, which is on whenever a report is delivered.
        var isEnabled = false
        /// Value changes by pass, for attributing coupling edges between a node's last convergence and the current pass.
        var valueChangeLog: [(passIndex: Int, nodeIDs: Set<Int>)] = []
        /// The pass at which each node's convergence was last recorded.
        var lastConvergencePass: [Int: Int] = [:]
        /// Sequence length when the pass in flight started, for its dispatch record.
        var baselineLength = 0
        /// Total distance to reduction targets when the pass in flight started, for its dispatch record.
        var baselineTargetDistance: Double = 0
    }

    /// Snapshots the sequence's length and target distance before a pass, for its dispatch record. Only with diagnostics.
    mutating func captureDispatchBaseline() {
        guard diagnostics.isEnabled else {
            return
        }
        diagnostics.baselineLength = incumbent.sequence.count
        diagnostics.baselineTargetDistance = sequenceTargetDistance()
    }

    /// Sums each value's pattern-space distance to its reduction target. Floating point, because full-range leaves contribute distances near 2^63 that would overflow an integer sum.
    func sequenceTargetDistance() -> Double {
        var total: Double = 0
        for entry in incumbent.sequence {
            guard let value = entry.value else {
                continue
            }
            let bitPattern = value.choice.bitPattern64
            let target = value.choice.reductionTarget(in: value.validRange)
            let distance = bitPattern.absoluteDifference(target)
            total += Double(distance)
        }
        return total
    }

    /// Attributes floor motion to the values that changed since each moving node last converged. Research diagnostics only.
    mutating func recordFloorMotion(_ motion: (structural: Int, value: Int, valueMotionNodeIDs: Set<Int>), convergedNodeIDs: [Int]) {
        for motionNodeID in motion.valueMotionNodeIDs {
            let sincePass = diagnostics.lastConvergencePass[motionNodeID] ?? 0
            var partnerNodes: Set<Int> = []
            for entry in diagnostics.valueChangeLog where entry.passIndex > sincePass {
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

        for nodeID in convergedNodeIDs {
            diagnostics.lastConvergencePass[nodeID] = passCounter
        }
    }

    /// Appends the pass to the dispatch log. Research diagnostics only.
    mutating func recordDispatch(_ pass: PassRecord) {
        let report = pass.report
        let distanceDelta = diagnostics.baselineTargetDistance - sequenceTargetDistance()
        stats.dispatchLog.append(DispatchRecord(
            cycle: cycles,
            passIndex: passCounter,
            encoderName: pass.encoderScope.encoder.name,
            probeCount: report.counts.emitted,
            acceptCount: report.counts.accepted,
            cacheHitCount: report.counts.rejectedByCache,
            decoderRejectCount: report.counts.decoderRejections,
            sequenceLengthDelta: diagnostics.baselineLength - incumbent.sequence.count,
            targetDistanceDelta: distanceDelta,
            boundValueFingerprint: pass.boundValueFingerprint,
            composedUpstreamLifts: nil,
            bindClassification: pass.boundValueFingerprint.flatMap { graph.bindClassifications[$0] }
        ))

        if report.anyAccepted, case .redistribution = pass.encoderScope {
            stats.redistributionAcceptanceNodeIDs.formUnion(report.acceptedLeafNodeIDs)
        }
    }
}
