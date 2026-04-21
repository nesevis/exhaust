// MARK: - Convergence Confirmation

extension ChoiceGraphScheduler {
    // swiftlint:disable function_parameter_count
    /// Probes each converged leaf at `floor - 1` to detect stale convergence bounds.
    ///
    /// If the property still fails at floor - 1, the convergence record was stale — the previous search stopped too early. Clears the stale record so minimization can re-enter for that leaf.
    ///
    /// - Returns: True if any stale floors were found and cleared.
    static func confirmConvergence(
        sequence: inout ChoiceSequence,
        tree: inout ChoiceTree,
        output: inout Any,
        graph: ChoiceGraph,
        gen: ReflectiveGenerator<Any>,
        property: @escaping (Any) -> Bool,
        rejectCache: inout Set<UInt64>,
        stats: inout ReductionStats,
        collectStats: Bool,
        isInstrumented: Bool
    ) throws -> Bool {
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

        // Bind status is structural — convergence probes are value-only and cannot add or remove bind markers. Hoisted to avoid an O(N) scan on every converged leaf.
        let hasBind = sequence.contains { entry in
            if case .bind = entry { return true }
            return false
        }

        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let origin = metadata.convergedOrigin else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }

            // Probe floor - 1 in bit-pattern space. The minimization encoder searches in bit-pattern space (directional), so convergence bounds are bit patterns and floor - 1 is the next adjacent value in the same search direction.
            let minBound: UInt64 = metadata.validRange?.lowerBound ?? 0
            guard origin.bound > minBound else { continue }

            let probeValue = origin.bound - 1
            var candidate = sequence
            candidate[range.lowerBound] = candidate[range.lowerBound]
                .withBitPattern(probeValue)
            guard candidate.shortLexPrecedes(sequence) else { continue }

            probeCount += 1

            let probeHash = ZobristHash.incrementalHash(
                baseHash: ZobristHash.hash(of: sequence),
                baseSequence: sequence,
                probe: candidate
            )
            if rejectCache.contains(probeHash) {
                cacheHitCount += 1
                continue
            }

            // Convergence confirmation rewrites a single converged leaf's bit pattern at `floor - 1` and re-runs the materializer.
            // By construction this is a pure value-only probe — no bind reshape, no structural pivot — so `materializePicks: false`
            // is safe and avoids the per-probe cost of re-materializing non-selected pick branches. The lazy rematerialize check in the cycle loop covers any path-changing operation that needs full branch metadata after a stale acceptance.
            let decoder: SequenceDecoder = hasBind
                ? .guided(fallbackTree: tree, materializePicks: false)
                : .exact(materializePicks: false)

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
                // Validation only: discard the probe's sequence even though it succeeded. Perturbing the leaf to `bound - 1` here would shift the leaf's value out from under ``GraphValueEncoder``, bypassing its cross-zero phase and trapping the leaf at a non-canonical local minimum. Clearing the convergence record alone lets value search re-enter the leaf next cycle from the same starting state it converged on originally.
                anyStale = true
                acceptCount += 1

                if case var .chooseBits(md) = graph.nodes[nodeID].kind {
                    md.convergedOrigin = nil
                    graph.nodes[nodeID] = ChoiceGraphNode(
                        id: graph.nodes[nodeID].id,
                        kind: .chooseBits(md),
                        positionRange: graph.nodes[nodeID].positionRange,
                        children: graph.nodes[nodeID].children,
                        parent: graph.nodes[nodeID].parent
                    )
                }

                if isInstrumented {
                    ExhaustLog.debug(
                        category: .reducer,
                        event: "stale_convergence_detected",
                        metadata: [
                            "position": "\(range.lowerBound)",
                            "old_floor": "\(origin.bound)",
                            "probe_succeeded_at": "\(probeValue)",
                        ]
                    )
                }
            } else {
                rejectCache.insert(probeHash)
                decoderRejectCount += 1
            }

            if collectStats {
                stats.totalMaterializations += 1
            }
        }

        return anyStale
    }

    // swiftlint:enable function_parameter_count
}
