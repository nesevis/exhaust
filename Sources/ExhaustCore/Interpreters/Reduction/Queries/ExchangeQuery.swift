//
//  ExchangeQuery.swift
//  Exhaust
//

// MARK: - Exchange Scope Query

/// Static scope builder for exchange operations (redistribution and tandem lockstep reduction).
///
/// Callers that also need minimization scopes should build ``QueryHelpers/buildInnerDescendantToBind(graph:)`` once and pass it to both ``build(graph:innerDescendantToBind:)`` and ``MinimizationQuery/build(graph:innerDescendantToBind:)``.
enum ExchangeQuery {
    /// Computes exchange scopes from type-compatibility edges, homogeneous group descriptors, and leaf groupings.
    ///
    /// Redistribution pairs any two type-compatible leaves where one is not at its reduction target. The source is zeroed and the receiver absorbs the delta. Homogeneous sequences (``SequenceMetadata/elementTypeTag`` non-nil) generate bounded pairs directly in O(C log C) without materializing type-compatibility edges. Heterogeneous sequences and mixed-type cross-zip pairs fall back to the precomputed edge set.
    ///
    /// - Parameters:
    ///   - graph: The current choice graph.
    ///   - innerDescendantToBind: Precomputed bind-inner index from ``QueryHelpers/buildInnerDescendantToBind(graph:)``. Pass a shared instance when also building minimization scopes so the same dictionary is reused across both families.
    /// - Returns: Redistribution scope (if pairs exist) and tandem scope (if same-typed leaf groups with at least two members exist).
    static func build(
        graph: ChoiceGraph,
        innerDescendantToBind: [Int: Int]
    ) -> [ExchangeScope] {
        var scopes: [ExchangeScope] = []

        // Redistribution from two sources:
        // 1. Homogeneous groups — bounded pairs generated directly.
        // 2. Heterogeneous edges — from precomputed typeCompatibilityEdges.
        var pairs: [RedistributionPair] = []
        pairs.append(contentsOf: homogeneousRedistributionPairs(
            graph: graph,
            innerDescendantToBind: innerDescendantToBind
        ))
        for edge in graph.typeCompatibilityEdges {
            // Bind-inner leaves control structure — redistributing them in either direction changes the bound's shape unpredictably. Depth-control leaves are independent markers for recursive depth and must not be redistributed. Only bound and independent values participate.
            guard QueryHelpers.isBindInner(edge.nodeA, innerDescendantToBind: innerDescendantToBind) == false,
                  QueryHelpers.isBindInner(edge.nodeB, innerDescendantToBind: innerDescendantToBind) == false,
                  QueryHelpers.isDepthControl(edge.nodeA, graph: graph) == false,
                  QueryHelpers.isDepthControl(edge.nodeB, graph: graph) == false
            else { continue }

            guard case let .chooseBits(metadataA) = graph.nodes[edge.nodeA].kind,
                  case let .chooseBits(metadataB) = graph.nodes[edge.nodeB].kind
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

            let positionA = graph.nodes[edge.nodeA].positionRange?.lowerBound ?? Int.max
            let positionB = graph.nodes[edge.nodeB].positionRange?.lowerBound ?? Int.max

            if positionA < positionB, distanceA > 0 {
                pairs.append(RedistributionPair(
                    source: QueryHelpers.makeLeafEntry(edge.nodeA, innerDescendantToBind: innerDescendantToBind),
                    sink: QueryHelpers.makeLeafEntry(edge.nodeB, innerDescendantToBind: innerDescendantToBind),
                    sourceTag: metadataA.typeTag,
                    sinkTag: metadataB.typeTag
                ))
            }
            if positionB < positionA, distanceB > 0 {
                pairs.append(RedistributionPair(
                    source: QueryHelpers.makeLeafEntry(edge.nodeB, innerDescendantToBind: innerDescendantToBind),
                    sink: QueryHelpers.makeLeafEntry(edge.nodeA, innerDescendantToBind: innerDescendantToBind),
                    sourceTag: metadataB.typeTag,
                    sinkTag: metadataA.typeTag
                ))
            }
        }
        if pairs.isEmpty == false {
            scopes.append(.redistribution(RedistributionScope(pairs: pairs)))
        }

        // Tandem: group active leaves by TypeTag. Depth-control leaves are excluded — they are independent recursive depth markers that must not move in lockstep with other values.
        var leafGroups: [TypeTag: [Int]] = [:]
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else { continue }
            if case .depthControl = metadata.typeTag { continue }
            leafGroups[metadata.typeTag, default: []].append(nodeID)
        }
        let tandemGroups = leafGroups.compactMap { tag, leafIDs -> TandemGroup? in
            guard leafIDs.count >= 2 else { return nil }
            let entries = leafIDs.map {
                QueryHelpers.makeLeafEntry($0, innerDescendantToBind: innerDescendantToBind)
            }
            return TandemGroup(leaves: entries, typeTag: tag)
        }
        if tandemGroups.isEmpty == false {
            scopes.append(.tandem(TandemScope(groups: tandemGroups)))
        }

        return scopes
    }

    /// Convenience overload that builds ``QueryHelpers/buildInnerDescendantToBind(graph:)`` on the caller's behalf. Prefer the primary overload when also building minimization scopes so the index is computed once and shared.
    static func build(graph: ChoiceGraph) -> [ExchangeScope] {
        build(
            graph: graph,
            innerDescendantToBind: QueryHelpers.buildInnerDescendantToBind(graph: graph)
        )
    }

    // MARK: - Homogeneous Redistribution Pairs

    /// Generates bounded redistribution pairs from homogeneous sequence groups and cross-zip homogeneous pairs.
    ///
    /// For each active sequence node with non-nil ``SequenceMetadata/elementTypeTag``, collects leaves, computes each leaf's distance from its reduction target, and pairs each non-target source with the first later-position leaf as a sink. For cross-zip pairs, finds homogeneous sequence children of each zip node with matching type tags and generates cross-group source-sink pairs.
    ///
    /// - Complexity: O(C log C) per sequence (dominated by the distance sort), O(groups) for cross-zip pairing. No O(C^2) enumeration.
    private static func homogeneousRedistributionPairs(
        graph: ChoiceGraph,
        innerDescendantToBind: [Int: Int]
    ) -> [RedistributionPair] {
        var pairs: [RedistributionPair] = []

        // Intra-sequence: each homogeneous sequence produces source-sink pairs among its own leaves. Depth-control tags are excluded — they are independent markers.
        for parentNodeID in graph.liveNodeIDs {
            let parentNode = graph.nodes[parentNodeID]
            guard case let .sequence(seqMetadata) = parentNode.kind else { continue }
            guard let tag = seqMetadata.elementTypeTag else { continue }
            if case .depthControl = tag { continue }

            let intraPairs = pairsFromHomogeneousLeaves(
                childIDs: parentNode.children,
                tag: tag,
                graph: graph,
                innerDescendantToBind: innerDescendantToBind
            )
            pairs.append(contentsOf: intraPairs)
        }

        // Cross-zip: for each zip, find pairs of homogeneous sequence children with matching type tags. Generate cross-group source-sink pairs where the source comes from the earlier-positioned group.
        for zipNodeID in graph.liveNodeIDs {
            let zipNode = graph.nodes[zipNodeID]
            guard case .zip = zipNode.kind else { continue }
            guard zipNode.children.count >= 2 else { continue }

            // Collect homogeneous sequence children with their tags.
            var homogeneousChildren: [(sequenceNodeID: Int, tag: TypeTag, children: [Int], minPosition: Int)] = []
            for childID in zipNode.children {
                guard let seqID = QueryHelpers.findSequenceBeneath(childID, graph: graph) else { continue }
                guard case let .sequence(seqMeta) = graph.nodes[seqID].kind else { continue }
                guard let tag = seqMeta.elementTypeTag else { continue }
                let minPos = graph.nodes[seqID].positionRange?.lowerBound ?? Int.max
                homogeneousChildren.append((
                    sequenceNodeID: seqID,
                    tag: tag,
                    children: graph.nodes[seqID].children,
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

                    // The earlier-positioned group provides sources, the later group provides sinks.
                    let (sourceGroup, sinkGroup) = groupA.minPosition < groupB.minPosition
                        ? (groupA, groupB)
                        : (groupB, groupA)

                    let crossPairs = crossGroupPairs(
                        sourceChildIDs: sourceGroup.children,
                        sinkChildIDs: sinkGroup.children,
                        tag: groupA.tag,
                        graph: graph,
                        innerDescendantToBind: innerDescendantToBind
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
    /// Sorts leaves by position, then for each source (distance from target > 0) pairs it with later-position leaves up to ``SchedulerTuning/maxPairLookahead`` positions ahead.
    private static func pairsFromHomogeneousLeaves(
        childIDs: [Int],
        tag: TypeTag,
        graph: ChoiceGraph,
        innerDescendantToBind: [Int: Int]
    ) -> [RedistributionPair] {
        var leaves: [(nodeID: Int, position: Int, distance: UInt64)] = []
        for childID in childIDs {
            guard QueryHelpers.isBindInner(childID, innerDescendantToBind: innerDescendantToBind) == false else { continue }
            guard case let .chooseBits(metadata) = graph.nodes[childID].kind else { continue }
            guard let range = graph.nodes[childID].positionRange else { continue }
            let target = metadata.value.reductionTarget(in: metadata.validRange)
            let distance = metadata.value.bitPattern64 > target
                ? metadata.value.bitPattern64 - target
                : target - metadata.value.bitPattern64
            leaves.append((nodeID: childID, position: range.lowerBound, distance: distance))
        }
        guard leaves.count >= 2 else { return [] }

        leaves.sort { $0.position < $1.position }

        var pairs: [RedistributionPair] = []
        for index in 0 ..< leaves.count {
            guard leaves[index].distance > 0 else { continue }
            let limit = min(leaves.count, index + 1 + SchedulerTuning.maxPairLookahead)
            for sinkIndex in (index + 1) ..< limit {
                pairs.append(RedistributionPair(
                    source: QueryHelpers.makeLeafEntry(leaves[index].nodeID, innerDescendantToBind: innerDescendantToBind),
                    sink: QueryHelpers.makeLeafEntry(leaves[sinkIndex].nodeID, innerDescendantToBind: innerDescendantToBind),
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
    private static func crossGroupPairs(
        sourceChildIDs: [Int],
        sinkChildIDs: [Int],
        tag: TypeTag,
        graph: ChoiceGraph,
        innerDescendantToBind: [Int: Int]
    ) -> [RedistributionPair] {
        // Find the first non-bind-inner sink leaf.
        var firstSinkID: Int?
        for childID in sinkChildIDs {
            guard graph.nodes[childID].positionRange != nil else { continue }
            if QueryHelpers.isBindInner(childID, innerDescendantToBind: innerDescendantToBind) == false {
                firstSinkID = childID
                break
            }
        }
        guard let firstSinkID else { return [] }

        var sources: [(nodeID: Int, distance: UInt64)] = []
        for childID in sourceChildIDs {
            guard QueryHelpers.isBindInner(childID, innerDescendantToBind: innerDescendantToBind) == false else { continue }
            guard case let .chooseBits(metadata) = graph.nodes[childID].kind else { continue }
            guard graph.nodes[childID].positionRange != nil else { continue }
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
                source: QueryHelpers.makeLeafEntry(source.nodeID, innerDescendantToBind: innerDescendantToBind),
                sink: QueryHelpers.makeLeafEntry(firstSinkID, innerDescendantToBind: innerDescendantToBind),
                sourceTag: tag,
                sinkTag: tag
            )
        }
    }
}
