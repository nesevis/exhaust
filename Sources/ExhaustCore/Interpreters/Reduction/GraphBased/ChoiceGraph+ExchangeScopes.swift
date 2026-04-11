//
//  ChoiceGraph+ExchangeScopes.swift
//  Exhaust
//

// MARK: - Exchange Scope Queries

extension ChoiceGraph {
    /// Computes exchange scopes from type-compatibility edges and leaf groupings.
    ///
    /// Redistribution pairs any two type-compatible leaves where one is not at its reduction target. The source is zeroed and the receiver absorbs the delta. Both intra-sequence and inter-sequence pairs are included — any type-compatible pair connected by a type-compatibility edge is a candidate.
    ///
    /// - Returns: Redistribution scope (if pairs exist) and tandem scope (if same-typed leaf groups with at least two members exist).
    func exchangeScopes() -> [ExchangeScope] {
        let innerChildToBind = buildInnerChildToBind()
        var scopes: [ExchangeScope] = []

        // Redistribution: pair any two type-compatible leaves where at least
        // one is not at its reduction target. The source (farther from target)
        // gets zeroed; the receiver absorbs the delta.
        var pairs: [RedistributionPair] = []
        for edge in typeCompatibilityEdges {
            guard case let .chooseBits(metadataA) = nodes[edge.nodeA].kind,
                  case let .chooseBits(metadataB) = nodes[edge.nodeB].kind
            else {
                continue
            }

            let targetA = metadataA.value.reductionTarget(in: metadataA.validRange)
            let targetB = metadataB.value.reductionTarget(in: metadataB.validRange)
            let distanceA = metadataA.value.bitPattern64 > targetA
                ? metadataA.value.bitPattern64 - targetA
                : targetA - metadataA.value.bitPattern64
            let distanceB = metadataB.value.bitPattern64 > targetB
                ? metadataB.value.bitPattern64 - targetB
                : targetB - metadataB.value.bitPattern64

            // Skip if both are already at target.
            guard distanceA > 0 || distanceB > 0 else { continue }

            // The source must be at an earlier position than the receiver
            // so that zeroing the source produces a shortlex-smaller candidate
            // (the first pairwise difference favors the candidate).
            let positionA = nodes[edge.nodeA].positionRange?.lowerBound ?? Int.max
            let positionB = nodes[edge.nodeB].positionRange?.lowerBound ?? Int.max

            // A is earlier — A can be the source (zeroed), B receives.
            if positionA < positionB, distanceA > 0 {
                pairs.append(RedistributionPair(
                    source: makeLeafEntry(edge.nodeA, innerChildToBind: innerChildToBind),
                    sink: makeLeafEntry(edge.nodeB, innerChildToBind: innerChildToBind),
                    sourceTag: metadataA.typeTag,
                    sinkTag: metadataB.typeTag
                ))
            }
            // B is earlier — B can be the source (zeroed), A receives.
            if positionB < positionA, distanceB > 0 {
                pairs.append(RedistributionPair(
                    source: makeLeafEntry(edge.nodeB, innerChildToBind: innerChildToBind),
                    sink: makeLeafEntry(edge.nodeA, innerChildToBind: innerChildToBind),
                    sourceTag: metadataB.typeTag,
                    sinkTag: metadataA.typeTag
                ))
            }
        }
        if pairs.isEmpty == false {
            scopes.append(.redistribution(RedistributionScope(pairs: pairs)))
        }

        // Tandem: group active leaves by TypeTag.
        var leafGroups: [TypeTag: [Int]] = [:]
        for nodeID in leafNodes {
            guard case let .chooseBits(metadata) = nodes[nodeID].kind else { continue }
            leafGroups[metadata.typeTag, default: []].append(nodeID)
        }
        let tandemGroups = leafGroups.compactMap { tag, leafIDs -> TandemGroup? in
            guard leafIDs.count >= 2 else { return nil }
            let entries = leafIDs.map { makeLeafEntry($0, innerChildToBind: innerChildToBind) }
            return TandemGroup(leaves: entries, typeTag: tag)
        }
        if tandemGroups.isEmpty == false {
            scopes.append(.tandem(TandemScope(groups: tandemGroups)))
        }

        return scopes
    }
}
