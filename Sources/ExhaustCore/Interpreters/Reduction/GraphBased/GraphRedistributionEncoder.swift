//
//  GraphRedistributionEncoder.swift
//  Exhaust
//

// MARK: - Graph Redistribution Encoder

/// Zeros one leaf by redistributing its magnitude to another along type-compatibility edges.
///
/// For each source-sink pair from the graph's type-compatibility edges, produces a single probe where the source is set to its reduction target and the sink absorbs the full delta. Pairs are ranked by Nash-gap regret with a tier boost for ``ConvergenceSignal/zeroingDependency`` signals.
///
/// This is the graph-based counterpart of ``RelaxRoundEncoder``. The graph provides the type-compatibility edges directly, so the encoder avoids the quadratic pair construction.
///
/// - SeeAlso: ``RelaxRoundEncoder``
public struct GraphRedistributionEncoder: GraphEncoder {
    public let name: EncoderName = .graphRedistribution

    // MARK: - State

    private var sequence = ChoiceSequence()
    private var probes: [RedistributionProbe] = []
    private var probeIndex = 0

    /// Maximum number of candidate pairs to evaluate before stopping.
    private static let probeLimit = 24

    private struct RedistributionProbe {
        let sourceIndex: Int
        let sinkIndex: Int
        let sourceTypeTag: TypeTag
    }

    // MARK: - GraphEncoder

    public mutating func start(
        graph: ChoiceGraph,
        sequence: ChoiceSequence,
        tree _: ChoiceTree
    ) {
        self.sequence = sequence
        probes = []
        probeIndex = 0

        // Build pairs from type-compatibility edges where one node is a source and the other is a sink.
        for edge in graph.typeCompatibilityEdges {
            let statusA = graph.sourceSinkStatus[edge.nodeA]
            let statusB = graph.sourceSinkStatus[edge.nodeB]

            let pairs: [(source: Int, sink: Int)]
            switch (statusA, statusB) {
            case (.source, .sink):
                pairs = [(edge.nodeA, edge.nodeB)]
            case (.sink, .source):
                pairs = [(edge.nodeB, edge.nodeA)]
            case (.source, .source):
                // Both are sources — try both directions.
                pairs = [(edge.nodeA, edge.nodeB), (edge.nodeB, edge.nodeA)]
            default:
                continue
            }

            for (sourceNodeID, sinkNodeID) in pairs {
                let sourceNode = graph.nodes[sourceNodeID]
                let sinkNode = graph.nodes[sinkNodeID]
                guard case let .chooseBits(sourceMetadata) = sourceNode.kind,
                      case .chooseBits = sinkNode.kind,
                      let sourceRange = sourceNode.positionRange,
                      let sinkRange = sinkNode.positionRange
                else { continue }

                probes.append(RedistributionProbe(
                    sourceIndex: sourceRange.lowerBound,
                    sinkIndex: sinkRange.lowerBound,
                    sourceTypeTag: sourceMetadata.typeTag
                ))
            }
        }

        // Sort by Nash-gap regret: pairs where both coordinates are stuck far from targets have the most redistributable energy.
        let seq = sequence
        probes.sort { lhs, rhs in
            let lhsScore = Self.pairRegret(lhs, in: seq)
            let rhsScore = Self.pairRegret(rhs, in: seq)
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }
            // Tiebreaker: prefer zeroing an earlier position.
            return lhs.sourceIndex < rhs.sourceIndex
        }
    }

    public mutating func nextProbe(lastAccepted _: Bool) -> ChoiceSequence? {
        while probeIndex < min(probes.count, Self.probeLimit) {
            let probe = probes[probeIndex]
            probeIndex += 1

            guard let sourceValue = sequence[probe.sourceIndex].value,
                  let sinkValue = sequence[probe.sinkIndex].value,
                  sourceValue.choice.tag == sinkValue.choice.tag
            else { continue }

            let sourceBitPattern = sourceValue.choice.bitPattern64
            let target = sourceValue.choice.reductionTarget(
                in: sourceValue.isRangeExplicit ? sourceValue.validRange : nil
            )
            guard sourceBitPattern != target else { continue }

            // Full delta: zero the source completely.
            let delta: UInt64
            let sourceMovesUpward: Bool
            if target > sourceBitPattern {
                delta = target - sourceBitPattern
                sourceMovesUpward = true
            } else {
                delta = sourceBitPattern - target
                sourceMovesUpward = false
            }

            // Compute new sink bit pattern.
            let sinkBitPattern = sinkValue.choice.bitPattern64
            let newSinkBitPattern: UInt64
            if sourceMovesUpward {
                guard sinkBitPattern >= delta else { continue }
                newSinkBitPattern = sinkBitPattern - delta
            } else {
                guard UInt64.max - delta >= sinkBitPattern else { continue }
                newSinkBitPattern = sinkBitPattern + delta
            }

            let newSourceChoice = ChoiceValue(
                sourceValue.choice.tag.makeConvertible(bitPattern64: target),
                tag: sourceValue.choice.tag
            )
            let newSinkChoice = ChoiceValue(
                sinkValue.choice.tag.makeConvertible(bitPattern64: newSinkBitPattern),
                tag: sinkValue.choice.tag
            )

            // Validate sink stays in range if range-explicit.
            if sinkValue.isRangeExplicit, newSinkChoice.fits(in: sinkValue.validRange) == false {
                continue
            }

            var candidate = sequence
            candidate[probe.sourceIndex] = .reduced(.init(
                choice: newSourceChoice,
                validRange: sourceValue.validRange,
                isRangeExplicit: sourceValue.isRangeExplicit
            ))
            candidate[probe.sinkIndex] = .value(.init(
                choice: newSinkChoice,
                validRange: sinkValue.validRange,
                isRangeExplicit: sinkValue.isRangeExplicit
            ))
            return candidate
        }
        return nil
    }

    // MARK: - Nash-Gap Regret

    /// Computes the priority score for a candidate pair, ranked by combined regret (bit-pattern distance from each coordinate's reduction target).
    private static func pairRegret(
        _ probe: RedistributionProbe,
        in sequence: ChoiceSequence
    ) -> UInt64 {
        let sourceRegret = distance(at: probe.sourceIndex, in: sequence)
        let sinkRegret = distance(at: probe.sinkIndex, in: sequence)
        return sourceRegret &+ sinkRegret
    }

    private static func distance(at index: Int, in sequence: ChoiceSequence) -> UInt64 {
        guard let value = sequence[index].value else { return 0 }
        let bitPattern = value.choice.bitPattern64
        let target = value.choice.reductionTarget(
            in: value.isRangeExplicit ? value.validRange : nil
        )
        return bitPattern > target ? bitPattern - target : target - bitPattern
    }
}
