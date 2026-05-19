// MARK: - Convergence Confirmation

extension ReductionMachine {
    /// Probes each converged leaf below its floor to detect stale convergence bounds.
    ///
    /// Tries `floor - 1` first. If that rejects and `floor - 2` is in range, tries that too (non-monotone gap detection). If either succeeds, the convergence record was stale — clears it so minimization can re-enter for that leaf.
    ///
    /// - Returns: True if any stale floors were found and cleared.
    mutating func confirmConvergence() throws -> Bool {
        var anyStale = false
        var probeCount = 0
        var acceptCount = 0
        var cacheHitCount = 0
        var decoderRejectCount = 0
        defer {
            if collectStats {
                stats.encoderProbes[.convergenceConfirmation, default: 0] += probeCount
                stats.encoderProbesAccepted[.convergenceConfirmation, default: 0] += acceptCount
                stats.encoderProbesRejectedByCache[.convergenceConfirmation, default: 0] += cacheHitCount
                stats.encoderProbesRejectedByDecoder[.convergenceConfirmation, default: 0] += decoderRejectCount
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
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let origin = metadata.convergedOrigin else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }

            let minBound: UInt64 = metadata.validRange?.lowerBound ?? 0
            guard origin.bound > minBound else { continue }

            let result = try probeBelow(
                value: origin.bound - 1,
                at: range.lowerBound,
                decoder: decoder,
                baseHash: baseHash,
                probeCount: &probeCount,
                cacheHitCount: &cacheHitCount,
                decoderRejectCount: &decoderRejectCount
            )

            if result == .accepted {
                anyStale = true
                acceptCount += 1
                clearConvergence(nodeID: nodeID)
                ChoiceGraphScheduler.logReducer("stale_convergence_detected", isInstrumented: isInstrumented, metadata: [
                    "position": "\(range.lowerBound)", "old_floor": "\(origin.bound)", "probe_succeeded_at": "\(origin.bound - 1)",
                ])
            } else if result == .rejected, origin.bound >= minBound + 2 {
                let gapResult = try probeBelow(
                    value: origin.bound - 2,
                    at: range.lowerBound,
                    decoder: decoder,
                    baseHash: baseHash,
                    probeCount: &probeCount,
                    cacheHitCount: &cacheHitCount,
                    decoderRejectCount: &decoderRejectCount
                )
                if gapResult == .accepted {
                    anyStale = true
                    acceptCount += 1
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
        probeCount: inout Int,
        cacheHitCount: inout Int,
        decoderRejectCount: inout Int
    ) throws -> ProbeResult {
        var candidate = sequence
        candidate[sequenceIndex] = candidate[sequenceIndex].withBitPattern(value)
        guard candidate.shortLexPrecedes(sequence) else { return .skipped }

        probeCount += 1

        let probeHash = ZobristHash.incrementalHash(
            baseHash: baseHash,
            baseSequence: sequence,
            probe: candidate
        )
        if rejectCache.contains(probeHash) {
            cacheHitCount += 1
            return .skipped
        }

        var filterObservations: [UInt64: FilterObservation] = [:]

        if try decoder.decodeAny(
            candidate: candidate,
            gen: gen,
            tree: tree,
            originalSequence: sequence,
            property: property,
            filterObservations: &filterObservations,
            precomputedHash: probeHash
        ) != nil {
            if collectStats {
                stats.totalMaterializations += 1
            }
            return .accepted
        }

        rejectCache.insert(probeHash)
        decoderRejectCount += 1
        if collectStats {
            stats.totalMaterializations += 1
        }
        return .rejected
    }

    private mutating func clearConvergence(nodeID: Int) {
        if case var .chooseBits(leafMetadata) = graph.nodes[nodeID].kind {
            leafMetadata.convergedOrigin = nil
            graph.nodes[nodeID] = graph.nodes[nodeID].with(kind: .chooseBits(leafMetadata))
        }
    }
}
