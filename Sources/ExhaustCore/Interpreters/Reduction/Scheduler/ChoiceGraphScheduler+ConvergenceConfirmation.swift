// MARK: - Convergence Confirmation

extension ChoiceGraphScheduler {
    /// Probes each converged leaf at `floor - 1` to detect stale convergence bounds.
    ///
    /// If the property still fails at floor - 1, the convergence record was stale — the previous search stopped too early. Clears the stale record so minimization can re-enter for that leaf.
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

        for nodeID in state.graph.leafNodes {
            guard case let .chooseBits(metadata) = state.graph.nodes[nodeID].kind else { continue }
            guard let origin = metadata.convergedOrigin else { continue }
            guard let range = state.graph.nodes[nodeID].positionRange else { continue }

            let minBound: UInt64 = metadata.validRange?.lowerBound ?? 0
            guard origin.bound > minBound else { continue }

            let probeValue = origin.bound - 1
            var candidate = state.sequence
            candidate[range.lowerBound] = candidate[range.lowerBound]
                .withBitPattern(probeValue)
            guard candidate.shortLexPrecedes(state.sequence) else { continue }

            probeCount += 1

            let probeHash = ZobristHash.incrementalHash(
                baseHash: ZobristHash.hash(of: state.sequence),
                baseSequence: state.sequence,
                probe: candidate
            )
            if state.rejectCache.contains(probeHash) {
                cacheHitCount += 1
                continue
            }

            let decoder: SequenceDecoder = hasBind
                ? .guided(fallbackTree: state.tree, materializePicks: false)
                : .exact(materializePicks: false)

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
                anyStale = true
                acceptCount += 1

                if case var .chooseBits(leafMetadata) = state.graph.nodes[nodeID].kind {
                    leafMetadata.convergedOrigin = nil
                    state.graph.nodes[nodeID] = state.graph.nodes[nodeID].with(kind: .chooseBits(leafMetadata))
                }

                Self.logReducer("stale_convergence_detected", isInstrumented: state.isInstrumented, metadata: [
                    "position": "\(range.lowerBound)", "old_floor": "\(origin.bound)", "probe_succeeded_at": "\(probeValue)",
                ])
            } else {
                state.rejectCache.insert(probeHash)
                decoderRejectCount += 1

                if origin.bound >= minBound + 2 {
                    let gapProbeValue = origin.bound - 2
                    var gapCandidate = state.sequence
                    gapCandidate[range.lowerBound] = gapCandidate[range.lowerBound]
                        .withBitPattern(gapProbeValue)

                    if gapCandidate.shortLexPrecedes(state.sequence) {
                        probeCount += 1

                        let gapHash = ZobristHash.incrementalHash(
                            baseHash: ZobristHash.hash(of: state.sequence),
                            baseSequence: state.sequence,
                            probe: gapCandidate
                        )

                        if state.rejectCache.contains(gapHash) {
                            cacheHitCount += 1
                        } else if try decoder.decodeAny(
                            candidate: gapCandidate,
                            gen: state.gen,
                            tree: state.tree,
                            originalSequence: state.sequence,
                            property: state.property,
                            filterObservations: &filterObservations,
                            precomputedHash: gapHash
                        ) != nil {
                            anyStale = true
                            acceptCount += 1

                            if case var .chooseBits(leafMetadata) = state.graph.nodes[nodeID].kind {
                                leafMetadata.convergedOrigin = nil
                                state.graph.nodes[nodeID] = state.graph.nodes[nodeID].with(kind: .chooseBits(leafMetadata))
                            }

                            Self.logReducer("non_monotone_convergence_detected", isInstrumented: state.isInstrumented, metadata: [
                                "position": "\(range.lowerBound)", "floor": "\(origin.bound)", "gap_probe_succeeded_at": "\(gapProbeValue)",
                            ])
                        } else {
                            state.rejectCache.insert(gapHash)
                            decoderRejectCount += 1
                        }

                        if state.collectStats {
                            state.stats.totalMaterializations += 1
                        }
                    }
                }
            }

            if state.collectStats {
                state.stats.totalMaterializations += 1
            }
        }

        return anyStale
    }
}
