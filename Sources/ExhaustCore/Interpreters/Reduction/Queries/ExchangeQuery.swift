//
//  ExchangeQuery.swift
//  Exhaust
//

// MARK: - Exchange Scope Query

/// Static scope builder for exchange operations (redistribution and tandem lockstep reduction).
enum ExchangeQuery {
    /// Computes exchange scopes from type-compatibility edges, homogeneous group descriptors, and leaf groupings.
    ///
    /// Reads ``ScopeAnnotation`` on each node for bind-inner and depth-control classification.
    static func build(graph: ChoiceGraph) -> [ExchangeScope] {
        var scopes: [ExchangeScope] = []

        var pairs: [RedistributionPair] = []
        pairs.append(contentsOf: homogeneousRedistributionPairs(graph: graph))
        for edge in graph.typeCompatibilityEdges {
            let annotationA = graph.nodes[edge.nodeA].scopeAnnotation
            let annotationB = graph.nodes[edge.nodeB].scopeAnnotation
            guard annotationA.isBindInner == false,
                  annotationB.isBindInner == false,
                  annotationA.isDepthControl == false,
                  annotationB.isDepthControl == false,
                  annotationA.isLaneControl == false,
                  annotationB.isLaneControl == false
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

            guard distanceA > 0 || distanceB > 0 else { continue }

            let positionA = graph.nodes[edge.nodeA].positionRange?.lowerBound ?? Int.max
            let positionB = graph.nodes[edge.nodeB].positionRange?.lowerBound ?? Int.max

            if positionA < positionB, distanceA > 0 {
                pairs.append(RedistributionPair(
                    source: leafEntry(for: edge.nodeA, graph: graph),
                    sink: leafEntry(for: edge.nodeB, graph: graph),
                    sourceTag: metadataA.typeTag,
                    sinkTag: metadataB.typeTag
                ))
            }
            if positionB < positionA, distanceB > 0 {
                pairs.append(RedistributionPair(
                    source: leafEntry(for: edge.nodeB, graph: graph),
                    sink: leafEntry(for: edge.nodeA, graph: graph),
                    sourceTag: metadataB.typeTag,
                    sinkTag: metadataA.typeTag
                ))
            }
        }
        if pairs.isEmpty == false {
            scopes.append(.redistribution(RedistributionScope(pairs: pairs)))
        }

        var leafGroups: [TypeTag: [Int]] = [:]
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else { continue }
            if node.scopeAnnotation.isDepthControl || node.scopeAnnotation.isLaneControl { continue }
            leafGroups[metadata.typeTag, default: []].append(nodeID)
        }
        let tandemGroups = leafGroups.compactMap { tag, leafIDs -> TandemGroup? in
            guard leafIDs.count >= 2 else { return nil }
            let entries = leafIDs.map { leafEntry(for: $0, graph: graph) }
            return TandemGroup(leaves: entries, typeTag: tag)
        }
        if tandemGroups.isEmpty == false {
            scopes.append(.tandem(TandemScope(groups: tandemGroups)))
        }

        if let relationScope = RelationQuery.build(graph: graph) {
            scopes.append(.relation(relationScope))
        }

        return scopes
    }

    // MARK: - Private Helpers

    private static func leafEntry(for nodeID: Int, graph: ChoiceGraph) -> LeafEntry {
        let annotation = graph.nodes[nodeID].scopeAnnotation
        return LeafEntry(
            nodeID: nodeID,
            mayReshapeOnAcceptance: annotation.isBindInner,
            bindDepth: annotation.controllingBindDepth
        )
    }

    // MARK: - Homogeneous Redistribution Pairs

    private static func homogeneousRedistributionPairs(
        graph: ChoiceGraph
    ) -> [RedistributionPair] {
        var pairs: [RedistributionPair] = []

        for parentNodeID in graph.liveNodeIDs {
            let parentNode = graph.nodes[parentNodeID]
            guard case let .sequence(seqMetadata) = parentNode.kind else { continue }
            guard let tag = seqMetadata.elementTypeTag else { continue }
            if case .depthControl = tag { continue }
            if case .laneControl = tag { continue }

            let intraPairs = pairsFromHomogeneousLeaves(
                childIDs: parentNode.children,
                tag: tag,
                graph: graph
            )
            pairs.append(contentsOf: intraPairs)
        }

        for zipNodeID in graph.liveNodeIDs {
            let zipNode = graph.nodes[zipNodeID]
            guard case .zip = zipNode.kind else { continue }
            guard zipNode.children.count >= 2 else { continue }

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

                    let (sourceGroup, sinkGroup) = groupA.minPosition < groupB.minPosition
                        ? (groupA, groupB)
                        : (groupB, groupA)

                    let crossPairs = crossGroupPairs(
                        sourceChildIDs: sourceGroup.children,
                        sinkChildIDs: sinkGroup.children,
                        tag: groupA.tag,
                        graph: graph
                    )
                    pairs.append(contentsOf: crossPairs)
                    indexB += 1
                }
                indexA += 1
            }
        }

        return pairs
    }

    private static func pairsFromHomogeneousLeaves(
        childIDs: [Int],
        tag: TypeTag,
        graph: ChoiceGraph
    ) -> [RedistributionPair] {
        var leaves: [(nodeID: Int, position: Int, distance: UInt64)] = []
        for childID in childIDs {
            guard graph.nodes[childID].scopeAnnotation.isBindInner == false else { continue }
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
            if index + 1 < leaves.count {
                pairs.append(RedistributionPair(
                    source: leafEntry(for: leaves[index].nodeID, graph: graph),
                    sink: leafEntry(for: leaves[index + 1].nodeID, graph: graph),
                    sourceTag: tag,
                    sinkTag: tag
                ))
            }
        }
        return pairs
    }

    private static func crossGroupPairs(
        sourceChildIDs: [Int],
        sinkChildIDs: [Int],
        tag: TypeTag,
        graph: ChoiceGraph
    ) -> [RedistributionPair] {
        var firstSinkID: Int?
        for childID in sinkChildIDs {
            guard graph.nodes[childID].positionRange != nil else { continue }
            if graph.nodes[childID].scopeAnnotation.isBindInner == false {
                firstSinkID = childID
                break
            }
        }
        guard let firstSinkID else { return [] }

        var sources: [(nodeID: Int, distance: UInt64)] = []
        for childID in sourceChildIDs {
            guard graph.nodes[childID].scopeAnnotation.isBindInner == false else { continue }
            guard case let .chooseBits(metadata) = graph.nodes[childID].kind else { continue }
            guard graph.nodes[childID].positionRange != nil else { continue }
            let target = metadata.value.reductionTarget(in: metadata.validRange)
            let distance = metadata.value.bitPattern64 > target
                ? metadata.value.bitPattern64 - target
                : target - metadata.value.bitPattern64
            guard distance > 0 else { continue }
            sources.append((nodeID: childID, distance: distance))
        }

        sources.sort { $0.distance > $1.distance }
        let budget = min(sources.count, GraphRedistributionEncoder.maxPairsPerScope)

        return sources.prefix(budget).map { source in
            RedistributionPair(
                source: leafEntry(for: source.nodeID, graph: graph),
                sink: leafEntry(for: firstSinkID, graph: graph),
                sourceTag: tag,
                sinkTag: tag
            )
        }
    }
}
