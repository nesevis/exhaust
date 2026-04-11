//
//  ChoiceGraph+ExchangeScopes.swift
//  Exhaust
//

// MARK: - Exchange Scope Queries

extension ChoiceGraph {
    /// Computes exchange scopes from type-compatibility edges, homogeneous group descriptors, and leaf groupings.
    ///
    /// Redistribution pairs any two type-compatible leaves where one is not at its reduction target. The source is zeroed and the receiver absorbs the delta. Homogeneous sequences (``SequenceMetadata/elementTypeTag`` non-nil) generate bounded pairs directly in O(C log C) without materializing type-compatibility edges. Heterogeneous sequences and mixed-type cross-zip pairs fall back to the precomputed edge set.
    ///
    /// - Returns: Redistribution scope (if pairs exist) and tandem scope (if same-typed leaf groups with at least two members exist).
    func exchangeScopes() -> [ExchangeScope] {
        let innerChildToBind = buildInnerChildToBind()
        var scopes: [ExchangeScope] = []

        // Redistribution from two sources:
        // 1. Homogeneous groups — bounded pairs generated directly.
        // 2. Heterogeneous edges — from precomputed typeCompatibilityEdges.
        var pairs: [RedistributionPair] = []
        pairs.append(contentsOf: homogeneousRedistributionPairs(innerChildToBind: innerChildToBind))
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

    // MARK: - Homogeneous Redistribution Pairs

    /// Generates bounded redistribution pairs from homogeneous sequence groups and cross-zip homogeneous pairs.
    ///
    /// For each active sequence node with non-nil ``SequenceMetadata/elementTypeTag``, collects leaves, computes each leaf's distance from its reduction target, and pairs each non-target source with the first later-position leaf as a sink. For cross-zip pairs, finds homogeneous sequence children of each zip node with matching type tags and generates cross-group source-sink pairs.
    ///
    /// - Complexity: O(C log C) per sequence (dominated by the distance sort), O(groups) for cross-zip pairing. No O(C^2) enumeration.
    private func homogeneousRedistributionPairs(
        innerChildToBind: [Int: Int]
    ) -> [RedistributionPair] {
        var pairs: [RedistributionPair] = []

        // Intra-sequence: each homogeneous sequence produces source-sink
        // pairs among its own leaves.
        for parentNode in nodes {
            guard parentNode.positionRange != nil else { continue }
            guard case let .sequence(seqMetadata) = parentNode.kind else { continue }
            guard let tag = seqMetadata.elementTypeTag else { continue }

            let intraPairs = pairsFromHomogeneousLeaves(
                childIDs: parentNode.children,
                tag: tag,
                innerChildToBind: innerChildToBind
            )
            pairs.append(contentsOf: intraPairs)
        }

        // Cross-zip: for each zip, find pairs of homogeneous sequence
        // children with matching type tags. Generate cross-group
        // source-sink pairs where the source comes from the
        // earlier-positioned group.
        for zipNode in nodes {
            guard case .zip = zipNode.kind else { continue }
            guard zipNode.positionRange != nil else { continue }
            guard zipNode.children.count >= 2 else { continue }

            // Collect homogeneous sequence children with their tags.
            var homogeneousChildren: [(sequenceNodeID: Int, tag: TypeTag, children: [Int], minPosition: Int)] = []
            for childID in zipNode.children {
                guard let seqID = findSequenceBeneath(childID) else { continue }
                guard case let .sequence(seqMeta) = nodes[seqID].kind else { continue }
                guard let tag = seqMeta.elementTypeTag else { continue }
                let minPos = nodes[seqID].positionRange?.lowerBound ?? Int.max
                homogeneousChildren.append((
                    sequenceNodeID: seqID,
                    tag: tag,
                    children: nodes[seqID].children,
                    minPosition: minPos
                ))
            }

            // For each pair of same-tagged groups, generate cross-group pairs.
            var indexA = 0
            while indexA < homogeneousChildren.count {
                var indexB = indexA + 1
                while indexB < homogeneousChildren.count {
                    let groupA = homogeneousChildren[indexA]
                    let groupB = homogeneousChildren[indexB]
                    guard groupA.tag == groupB.tag else {
                        indexB += 1
                        continue
                    }

                    // The earlier-positioned group provides sources,
                    // the later group provides sinks.
                    let (sourceGroup, sinkGroup) = groupA.minPosition < groupB.minPosition
                        ? (groupA, groupB)
                        : (groupB, groupA)

                    let crossPairs = crossGroupPairs(
                        sourceChildIDs: sourceGroup.children,
                        sinkChildIDs: sinkGroup.children,
                        tag: groupA.tag,
                        innerChildToBind: innerChildToBind
                    )
                    pairs.append(contentsOf: crossPairs)
                    indexB += 1
                }
                indexA += 1
            }
        }

        return pairs
    }

    /// Generates source-sink pairs from leaves within a single homogeneous group.
    ///
    /// Sorts leaves by position, then for each source (distance from target > 0) pairs it with the first later-position leaf. Produces at most C-1 pairs for C leaves.
    private func pairsFromHomogeneousLeaves(
        childIDs: [Int],
        tag: TypeTag,
        innerChildToBind: [Int: Int]
    ) -> [RedistributionPair] {
        // Collect leaves with position and distance.
        var leaves: [(nodeID: Int, position: Int, distance: UInt64)] = []
        for childID in childIDs {
            guard case let .chooseBits(metadata) = nodes[childID].kind else { continue }
            guard let range = nodes[childID].positionRange else { continue }
            let target = metadata.value.reductionTarget(in: metadata.validRange)
            let distance = metadata.value.bitPattern64 > target
                ? metadata.value.bitPattern64 - target
                : target - metadata.value.bitPattern64
            leaves.append((nodeID: childID, position: range.lowerBound, distance: distance))
        }
        guard leaves.count >= 2 else { return [] }

        // Sort by position for the shortlex ordering constraint.
        leaves.sort { $0.position < $1.position }

        var pairs: [RedistributionPair] = []
        for index in 0 ..< leaves.count {
            guard leaves[index].distance > 0 else { continue }
            // Pair with the first later-position leaf.
            if index + 1 < leaves.count {
                pairs.append(RedistributionPair(
                    source: makeLeafEntry(leaves[index].nodeID, innerChildToBind: innerChildToBind),
                    sink: makeLeafEntry(leaves[index + 1].nodeID, innerChildToBind: innerChildToBind),
                    sourceTag: tag,
                    sinkTag: tag
                ))
            }
        }
        return pairs
    }

    /// Generates cross-group source-sink pairs between two homogeneous groups of the same type.
    ///
    /// Takes the top sources from the source group by distance and pairs each with the first leaf in the sink group.
    private func crossGroupPairs(
        sourceChildIDs: [Int],
        sinkChildIDs: [Int],
        tag: TypeTag,
        innerChildToBind: [Int: Int]
    ) -> [RedistributionPair] {
        guard let firstSinkID = sinkChildIDs.first else { return [] }
        guard nodes[firstSinkID].positionRange != nil else { return [] }

        var sources: [(nodeID: Int, distance: UInt64)] = []
        for childID in sourceChildIDs {
            guard case let .chooseBits(metadata) = nodes[childID].kind else { continue }
            guard nodes[childID].positionRange != nil else { continue }
            let target = metadata.value.reductionTarget(in: metadata.validRange)
            let distance = metadata.value.bitPattern64 > target
                ? metadata.value.bitPattern64 - target
                : target - metadata.value.bitPattern64
            guard distance > 0 else { continue }
            sources.append((nodeID: childID, distance: distance))
        }

        // Take sources with the largest distance.
        sources.sort { $0.distance > $1.distance }
        let budget = min(sources.count, GraphRedistributionEncoder.maxPairsPerScope)

        return sources.prefix(budget).map { source in
            RedistributionPair(
                source: makeLeafEntry(source.nodeID, innerChildToBind: innerChildToBind),
                sink: makeLeafEntry(firstSinkID, innerChildToBind: innerChildToBind),
                sourceTag: tag,
                sinkTag: tag
            )
        }
    }

}
