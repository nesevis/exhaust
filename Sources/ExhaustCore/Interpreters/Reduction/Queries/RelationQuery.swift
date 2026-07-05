//
//  RelationQuery.swift
//  Exhaust
//

// MARK: - Relation Scope Query

/// Static scope builder for relation search over stall-converged leaf pairs.
///
/// The stall gate is the whole design: a pair is eligible only when both leaves carry a convergence record equal to their current bit pattern while sitting above their reduction targets. Value search produces that state exactly when no single-leaf reduction exists, so the query fires after every cheaper move has been certified futile, and it can never displace an encoder that still has work. On uncoupled workloads leaves converge at their targets or keep moving, so the gate stays closed.
///
/// The relation is inferred in semantic-magnitude space, not bit-pattern space: signed integers use an XOR sign-magnitude encoding where the pattern of a small positive value is the sign-bit mask plus the value, so a ratio between raw patterns is meaningless. Each leaf's magnitude is its distance above the semantic-zero pattern, which recovers the value-space ratio for every integer tag.
enum RelationQuery {
    /// Upper bound on the reduced ratio components. A pair whose reduced numerator or denominator exceeds this is treated as unrelated: large components mean the current magnitudes share only an incidental divisor, and probing along that line would waste the budget on a relation the generator almost certainly does not encode.
    static let ratioCap: UInt64 = 16

    /// Builds the relation scope from stall-converged integer leaves, or nil when no eligible pair exists.
    static func build(graph: ChoiceGraph) -> RelationScope? {
        var stalledLeaves: [(nodeID: Int, position: Int, magnitude: UInt64)] = []
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else {
                continue
            }
            let annotation = node.scopeAnnotation
            if annotation.isDepthControl || annotation.isLaneControl || annotation.isBindInner {
                continue
            }
            guard metadata.typeTag.isFloatingPoint == false else {
                continue
            }
            guard let range = node.positionRange else {
                continue
            }

            let bitPattern = metadata.value.bitPattern64
            let target = metadata.value.reductionTarget(in: metadata.validRange)
            guard bitPattern != target else {
                continue
            }
            let zeroBitPattern = metadata.value.semanticSimplest.bitPattern64
            guard bitPattern > zeroBitPattern else {
                continue
            }
            guard let record = graph.convergenceStore[nodeID], record.bound == bitPattern else {
                continue
            }

            stalledLeaves.append((
                nodeID: nodeID,
                position: range.lowerBound,
                magnitude: bitPattern - zeroBitPattern
            ))
        }
        guard stalledLeaves.count >= 2 else {
            return nil
        }
        stalledLeaves.sort { $0.position < $1.position }

        var pairs: [RelationPair] = []
        var firstIndex = 0
        while firstIndex < stalledLeaves.count, pairs.count < GraphRedistributionEncoder.maxPairsPerScope {
            var secondIndex = firstIndex + 1
            while secondIndex < stalledLeaves.count, pairs.count < GraphRedistributionEncoder.maxPairsPerScope {
                let first = stalledLeaves[firstIndex]
                let second = stalledLeaves[secondIndex]
                secondIndex += 1

                guard tagsMatch(first.nodeID, second.nodeID, graph: graph) else {
                    continue
                }

                let scale = greatestCommonDivisor(first.magnitude, second.magnitude)
                guard scale >= 2 else {
                    continue
                }
                let numerator = first.magnitude / scale
                let denominator = second.magnitude / scale
                // Equal magnitudes reduce to 1:1, which is the common-delta diagonal lockstep already searches.
                guard numerator != denominator else {
                    continue
                }
                guard max(numerator, denominator) <= ratioCap else {
                    continue
                }

                pairs.append(RelationPair(
                    first: leafEntry(for: first.nodeID, graph: graph),
                    second: leafEntry(for: second.nodeID, graph: graph),
                    numerator: numerator,
                    denominator: denominator,
                    scale: scale
                ))
            }
            firstIndex += 1
        }

        guard pairs.isEmpty == false else {
            return nil
        }
        return RelationScope(pairs: pairs)
    }

    // MARK: - Private Helpers

    private static func tagsMatch(_ nodeA: Int, _ nodeB: Int, graph: ChoiceGraph) -> Bool {
        guard case let .chooseBits(metadataA) = graph.nodes[nodeA].kind,
              case let .chooseBits(metadataB) = graph.nodes[nodeB].kind
        else {
            return false
        }
        return metadataA.typeTag == metadataB.typeTag
    }

    private static func leafEntry(for nodeID: Int, graph: ChoiceGraph) -> LeafEntry {
        let annotation = graph.nodes[nodeID].scopeAnnotation
        return LeafEntry(
            nodeID: nodeID,
            mayReshapeOnAcceptance: annotation.isBindInner,
            bindDepth: annotation.controllingBindDepth
        )
    }

    private static func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var a = lhs
        var b = rhs
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return a
    }
}
