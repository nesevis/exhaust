// MARK: - Convergence Confirmation

extension ReductionSession {
    /// Tests up to two steps from each floor toward its target and returns the first smaller failing counterexample. Cached rejections still advance to the next step. Returning immediately keeps every remaining graph address tied to the checkpoint it came from.
    mutating func confirmConvergence() -> PostCycleResult {
        var counts = ReductionProbeCounts()
        defer {
            stats.record(counts, for: .convergenceConfirmation)
        }
        let selection: ReductionDecoder.Selection = hasBind
            ? .guided(materializePicks: false)
            : .exact(materializePicks: false, admission: .standard)

        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind,
                  let origin = graph.convergenceStore[nodeID],
                  let range = graph.nodes[nodeID].positionRange
            else {
                continue
            }
            let target = metadata.value.reductionTarget(in: metadata.validRange)
            let distance = origin.bound.absoluteDifference(target)
            guard distance > 0 else {
                continue
            }
            for step in 1 ... min(2, distance) {
                guard deadline.isExpired == false else {
                    return .unchanged
                }
                let value = origin.bound > target ? origin.bound - step : origin.bound + step
                let result = probeCloser(value: value, at: range.lowerBound, selection: selection, counts: &counts)
                if case .recovered = result {
                    graph.clearConvergence(nodeID)
                    ReductionLog.reducer("convergence_witness_found", isInstrumented: isInstrumented, metadata: [
                        "position": "\(range.lowerBound)",
                        "old_floor": "\(origin.bound)",
                        "probe_succeeded_at": "\(value)",
                    ])
                    return result
                }
            }
        }
        return .unchanged
    }

    /// Keeps the decoded witness instead of relying on a subsequent search to rediscover it. Strict admission prevents an equal or enlarging decode from renewing the stall budget indefinitely.
    private mutating func probeCloser(
        value: UInt64,
        at sequenceIndex: Int,
        selection: ReductionDecoder.Selection,
        counts: inout ReductionProbeCounts
    ) -> PostCycleResult {
        var candidate = incumbent.sequence
        candidate[sequenceIndex] = candidate[sequenceIndex].withBitPattern(value)
        guard candidate.shortLexPrecedes(incumbent.sequence) else {
            return .unchanged
        }
        counts.recordEmission()
        let probeHash = ZobristHash.incrementalHash(
            baseHash: incumbentHash,
            baseSequence: incumbent.sequence,
            probe: candidate
        )
        let lookup = rejectCache.lookup(
            probeHash: probeHash,
            decision: ProbeDecision(selection, order: .strictlySmaller),
            incumbentHash: incumbentHash
        )
        let evaluation = CandidateEvaluator.evaluate(
            candidate,
            against: incumbent,
            using: selection,
            decoder: decoder,
            admits: { [incumbent] in incumbent.admits($0, under: .strictlySmaller) },
            lookup: lookup,
            cache: &rejectCache,
            counts: &counts
        )
        guard case let .admitted(recovered, decoding) = evaluation else {
            return .unchanged
        }
        counts.recordAcceptance()
        return .recovered(recovered, isTreeStripped: decoding.selection.materializePicks == false)
    }
}
