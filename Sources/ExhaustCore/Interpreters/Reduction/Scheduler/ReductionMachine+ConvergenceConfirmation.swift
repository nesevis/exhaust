// MARK: - Convergence Confirmation

extension ReductionMachine {
    /// Probes each converged leaf below its floor to detect stale convergence bounds.
    ///
    /// Tries `floor - 1` first. If that rejects and `floor - 2` is in range, tries that too (non-monotone gap detection). If either succeeds, the convergence record was stale — clears it so minimization can re-enter for that leaf.
    ///
    /// - Returns: True if any stale floors were found and cleared.
    mutating func confirmConvergence() throws -> Bool {
        var anyStale = false
        var counts = ReductionProbeCounts()
        defer {
            if collectStats {
                stats.record(counts, for: .convergenceConfirmation)
            }
        }

        let hasBind = sequence.contains { entry in
            if case .bind = entry { return true }
            return false
        }
        let decoder: SequenceDecoder = hasBind
            ? .guided(fallbackTree: tree, materializePicks: false)
            : .exact(materializePicks: false)
        let baseHash = ZobristHash.hash(of: sequence)

        for nodeID in graph.leafNodes {
            if isDeadlineExceeded() { break }
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let origin = graph.convergenceStore[nodeID] else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }

            let minBound: UInt64 = metadata.validRange?.lowerBound ?? 0
            guard origin.bound > minBound else { continue }

            let result = try probeBelow(
                value: origin.bound - 1,
                at: range.lowerBound,
                decoder: decoder,
                baseHash: baseHash,
                counts: &counts
            )

            if result == .accepted {
                anyStale = true
                clearConvergence(nodeID: nodeID)
                ChoiceGraphScheduler.logReducer("stale_convergence_detected", isInstrumented: isInstrumented, metadata: [
                    "position": "\(range.lowerBound)", "old_floor": "\(origin.bound)", "probe_succeeded_at": "\(origin.bound - 1)",
                ])
            } else if result == .rejected, origin.bound - minBound >= 2 {
                let gapResult = try probeBelow(
                    value: origin.bound - 2,
                    at: range.lowerBound,
                    decoder: decoder,
                    baseHash: baseHash,
                    counts: &counts
                )
                if gapResult == .accepted {
                    anyStale = true
                    clearConvergence(nodeID: nodeID)
                    ChoiceGraphScheduler.logReducer("non_monotone_convergence_detected", isInstrumented: isInstrumented, metadata: [
                        "position": "\(range.lowerBound)", "floor": "\(origin.bound)", "gap_probe_succeeded_at": "\(origin.bound - 2)",
                    ])
                }
            }
        }

        return anyStale
    }

    private enum ProbeResult {
        case accepted
        case rejected
        case skipped
    }

    private mutating func probeBelow(
        value: UInt64,
        at sequenceIndex: Int,
        decoder: SequenceDecoder,
        baseHash: UInt64,
        counts: inout ReductionProbeCounts
    ) throws -> ProbeResult {
        var candidate = sequence
        candidate[sequenceIndex] = candidate[sequenceIndex].withBitPattern(value)
        guard candidate.shortLexPrecedes(sequence) else { return .skipped }

        counts.recordEmission()

        let probeHash = ZobristHash.incrementalHash(
            baseHash: baseHash,
            baseSequence: sequence,
            probe: candidate
        )
        if rejectCache.contains(probeHash) {
            counts.recordCacheRejection()
            return .skipped
        }

        var filterObservations: [UInt64: FilterObservation] = [:]

        let outcome = try decoder.decodeAny(
            candidate: candidate,
            gen: gen,
            tree: tree,
            originalSequence: sequence,
            property: property,
            filterObservations: &filterObservations,
            precomputedHash: probeHash
        )
        counts.record(outcome)
        if outcome.reduction != nil {
            return .accepted
        }

        rejectCache.insert(probeHash)
        return .rejected
    }

    private mutating func clearConvergence(nodeID: Int) {
        graph.clearConvergence(nodeID)
    }
}
