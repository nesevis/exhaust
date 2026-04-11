//
//  ChoiceGraphScheduler+Staleness.swift
//  Exhaust
//

// MARK: - Staleness Detection

extension ChoiceGraphScheduler {
    // swiftlint:disable function_parameter_count
    /// Probes each converged leaf at `floor - 1` to detect stale convergence bounds.
    ///
    /// If the property still fails at floor - 1, the convergence record was stale — the previous search stopped too early. Clears the stale record so minimization can re-enter for that leaf.
    ///
    /// - Returns: True if any stale floors were found and cleared.
    static func detectStaleness(
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
        // Per-encoder breakdown for the wasted-mats investigation.
        // The probe count here is bounded by the number of converged
        // leaves. Cache hits and decoder rejections both apply.
        var stalenessProbeCount = 0
        var stalenessAcceptCount = 0
        var stalenessCacheHitCount = 0
        var stalenessDecoderRejectCount = 0
        defer {
            if collectStats {
                stats.encoderProbes[.graphStaleness, default: 0] += stalenessProbeCount
                stats.encoderProbesAccepted[.graphStaleness, default: 0] += stalenessAcceptCount
                stats.encoderProbesRejectedByCache[.graphStaleness, default: 0] += stalenessCacheHitCount
                stats.encoderProbesRejectedByDecoder[.graphStaleness, default: 0] += stalenessDecoderRejectCount
            }
        }

        // Bind status is structural — staleness probes are value-only and
        // cannot add or remove bind markers. Hoisted to avoid an O(N) scan
        // on every converged leaf.
        let hasBind = sequence.contains { entry in
            if case .bind = entry { return true }
            return false
        }

        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let origin = metadata.convergedOrigin else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }

            // Probe floor - 1 in bit-pattern space. The minimization
            // encoder searches in bit-pattern space (directional), so
            // convergence bounds are bit patterns and floor - 1 is the
            // next adjacent value in the same search direction.
            let minBound: UInt64 = metadata.validRange?.lowerBound ?? 0
            guard origin.bound > minBound else { continue }

            let probeValue = origin.bound - 1
            var candidate = sequence
            candidate[range.lowerBound] = candidate[range.lowerBound]
                .withBitPattern(probeValue)
            guard candidate.shortLexPrecedes(sequence) else { continue }

            stalenessProbeCount += 1

            let probeHash = ZobristHash.incrementalHash(
                baseHash: ZobristHash.hash(of: sequence),
                baseSequence: sequence,
                probe: candidate
            )
            if rejectCache.contains(probeHash) {
                stalenessCacheHitCount += 1
                continue
            }

            // Layer 6: ``detectStaleness`` rewrites a single converged
            // leaf's bit pattern at `floor - 1` and re-runs the materializer.
            // By construction this is a pure value-only probe — no bind
            // reshape, no structural pivot — so `materializePicks: false`
            // is safe and avoids the per-probe cost of re-materializing
            // non-selected pick branches. The lazy rematerialize check
            // in the cycle loop covers any path-changing operation that
            // needs full branch metadata after a stale acceptance.
            let decoder: SequenceDecoder = hasBind
                ? .guided(fallbackTree: tree, materializePicks: false)
                : .exact(materializePicks: false)

            var filterObservations: [UInt64: FilterObservation] = [:]

            if let result = try decoder.decodeAny(
                candidate: candidate,
                gen: gen,
                tree: tree,
                originalSequence: sequence,
                property: property,
                filterObservations: &filterObservations,
                precomputedHash: probeHash
            ) {
                sequence = result.sequence
                tree = result.tree
                output = result.output
                anyStale = true
                stalenessAcceptCount += 1

                // Clear the stale convergence record.
                graph.recordConvergence(byNodeID: [nodeID: ConvergedOrigin(
                    bound: probeValue,
                    signal: .monotoneConvergence,
                    configuration: origin.configuration,
                    cycle: origin.cycle
                )])

                if isInstrumented {
                    ExhaustLog.debug(
                        category: .reducer,
                        event: "staleness_detected",
                        metadata: [
                            "position": "\(range.lowerBound)",
                            "old_floor": "\(origin.bound)",
                            "new_floor": "\(probeValue)",
                        ]
                    )
                }
            } else {
                rejectCache.insert(probeHash)
                stalenessDecoderRejectCount += 1
            }

            if collectStats {
                stats.totalMaterializations += 1
            }
        }

        return anyStale
    }

    // swiftlint:enable function_parameter_count
}
