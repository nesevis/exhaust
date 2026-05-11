// MARK: - Convergence Confirmation

extension ChoiceGraphScheduler {
    /// Probes each converged leaf below its floor to detect stale convergence bounds.
    ///
    /// Tries `floor - 1` first. If that rejects and `floor - 2` is in range, tries that too (non-monotone gap detection). If either succeeds, the convergence record was stale — clears it so minimization can re-enter for that leaf.
    ///
    /// - Returns: True if any stale floors were found and cleared.
    static func confirmConvergence(state: inout ReductionState) throws -> Bool {
        var anyStale = false
        var probeCount = 0
        var acceptCount = 0
        var cacheHitCount = 0
        var decoderRejectCount = 0
        defer {
            if state.collectStats {
                state.stats.encoderProbes[.convergenceConfirmation, default: 0] += probeCount
                state.stats.encoderProbesAccepted[.convergenceConfirmation, default: 0] += acceptCount
                state.stats.encoderProbesRejectedByCache[.convergenceConfirmation, default: 0] += cacheHitCount
                state.stats.encoderProbesRejectedByDecoder[.convergenceConfirmation, default: 0] += decoderRejectCount
            }
        }

        let hasBind = state.sequence.contains { entry in
            if case .bind = entry { return true }
            return false
        }
        let decoder: SequenceDecoder = hasBind
            ? .guided(fallbackTree: state.tree, materializePicks: false)
            : .exact(materializePicks: false)
        let baseHash = ZobristHash.hash(of: state.sequence)

        for nodeID in state.graph.leafNodes {
            guard case let .chooseBits(metadata) = state.graph.nodes[nodeID].kind else { continue }
            guard let origin = metadata.convergedOrigin else { continue }
            guard let range = state.graph.nodes[nodeID].positionRange else { continue }

            let minBound: UInt64 = metadata.validRange?.lowerBound ?? 0
            guard origin.bound > minBound else { continue }

            let result = try probeBelow(
                value: origin.bound - 1,
                at: range.lowerBound,
                decoder: decoder,
                baseHash: baseHash,
                state: &state,
                probeCount: &probeCount,
                cacheHitCount: &cacheHitCount,
                decoderRejectCount: &decoderRejectCount
            )

            if result == .accepted {
                anyStale = true
                acceptCount += 1
                clearConvergence(nodeID: nodeID, state: &state)
                Self.logReducer("stale_convergence_detected", isInstrumented: state.isInstrumented, metadata: [
                    "position": "\(range.lowerBound)", "old_floor": "\(origin.bound)", "probe_succeeded_at": "\(origin.bound - 1)",
                ])
            } else if result == .rejected, origin.bound >= minBound + 2 {
                let gapResult = try probeBelow(
                    value: origin.bound - 2,
                    at: range.lowerBound,
                    decoder: decoder,
                    baseHash: baseHash,
                    state: &state,
                    probeCount: &probeCount,
                    cacheHitCount: &cacheHitCount,
                    decoderRejectCount: &decoderRejectCount
                )
                if gapResult == .accepted {
                    anyStale = true
                    acceptCount += 1
                    clearConvergence(nodeID: nodeID, state: &state)
                    Self.logReducer("non_monotone_convergence_detected", isInstrumented: state.isInstrumented, metadata: [
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

    private static func probeBelow(
        value: UInt64,
        at sequenceIndex: Int,
        decoder: SequenceDecoder,
        baseHash: UInt64,
        state: inout ReductionState,
        probeCount: inout Int,
        cacheHitCount: inout Int,
        decoderRejectCount: inout Int
    ) throws -> ProbeResult {
        var candidate = state.sequence
        candidate[sequenceIndex] = candidate[sequenceIndex].withBitPattern(value)
        guard candidate.shortLexPrecedes(state.sequence) else { return .skipped }

        probeCount += 1

        let probeHash = ZobristHash.incrementalHash(
            baseHash: baseHash,
            baseSequence: state.sequence,
            probe: candidate
        )
        if state.rejectCache.contains(probeHash) {
            cacheHitCount += 1
            return .skipped
        }

        var filterObservations: [UInt64: FilterObservation] = [:]

        if try decoder.decodeAny(
            candidate: candidate,
            gen: state.gen,
            tree: state.tree,
            originalSequence: state.sequence,
            property: state.property,
            filterObservations: &filterObservations,
            precomputedHash: probeHash
        ) != nil {
            if state.collectStats {
                state.stats.totalMaterializations += 1
            }
            return .accepted
        }

        state.rejectCache.insert(probeHash)
        decoderRejectCount += 1
        if state.collectStats {
            state.stats.totalMaterializations += 1
        }
        return .rejected
    }

    private static func clearConvergence(nodeID: Int, state: inout ReductionState) {
        if case var .chooseBits(leafMetadata) = state.graph.nodes[nodeID].kind {
            leafMetadata.convergedOrigin = nil
            state.graph.nodes[nodeID] = state.graph.nodes[nodeID].with(kind: .chooseBits(leafMetadata))
        }
    }
}
