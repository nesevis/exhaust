//
//  ExchangeQuery.swift
//  Exhaust
//

// MARK: - Exchange Scope Query

/// Static scope builder for exchange operations (redistribution, tandem lockstep reduction, relation search, and bound exchange).
enum ExchangeQuery {
    /// Computes exchange scopes from type-compatibility edges, homogeneous group descriptors, and leaf groupings.
    ///
    /// A redistribution pair moves value between leaves controlling the same bind, or between independent leaves, never across binds. Only type-compatibility edges can span binds. Homogeneous pairs never do: the children of one sequence share its bind role, which ``ChoiceGraphBuilder`` assigns from the walk context, and ``QueryHelpers/findSequenceBeneath(_:graph:)`` never descends into a bind's inner subtree, so every sequence it finds beneath a zip shares the zip's bind role.
    static func build(graph: ChoiceGraph) -> [ExchangeScope] {
        var scopes: [ExchangeScope] = []

        var pairs: [RedistributionPair] = []
        pairs.append(contentsOf: homogeneousRedistributionPairs(graph: graph))
        for edge in graph.typeCompatibilityEdges {
            let annotationA = graph.nodes[edge.nodeA].scopeAnnotation
            let annotationB = graph.nodes[edge.nodeB].scopeAnnotation
            guard annotationA.controllingBindNodeID == annotationB.controllingBindNodeID,
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

        var tandemGroups: [TandemGroup] = []
        for (tag, nodeIdentifiers) in leafGroups where nodeIdentifiers.count >= 2 {
            let entries = nodeIdentifiers.map { leafEntry(for: $0, graph: graph) }
            tandemGroups.append(TandemGroup(leaves: entries, typeTag: tag))
            for matchingNodeIdentifiers in equalValueSubgroups(of: nodeIdentifiers, graph: graph) {
                let matchingEntries = matchingNodeIdentifiers.map { leafEntry(for: $0, graph: graph) }
                tandemGroups.append(TandemGroup(leaves: matchingEntries, typeTag: tag))
            }
        }

        // Dictionary iteration order varies with the per-process hash seed. The broader type group precedes an equal-value subgroup at the same position so the existing search order remains first.
        tandemGroups.sort { groupA, groupB in
            let positionA = graph.nodes[groupA.leaves[0].nodeID].positionRange?.lowerBound ?? 0
            let positionB = graph.nodes[groupB.leaves[0].nodeID].positionRange?.lowerBound ?? 0
            if positionA != positionB {
                return positionA < positionB
            }
            return groupA.leaves.count > groupB.leaves.count
        }
        if tandemGroups.isEmpty == false {
            scopes.append(.tandem(TandemScope(groups: tandemGroups)))
        }

        if let relationScope = RelationQuery.build(graph: graph) {
            scopes.append(.relation(relationScope))
        }

        scopes.append(contentsOf: boundExchangeScopes(graph: graph).map { .boundExchange($0) })

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

    // MARK: - Bound Exchange Scopes

    /// Builds one exchange per bind inner off its target and each same-type leaf its bind determines further down a composable chain.
    ///
    /// Lowering an outer bind inner while raising a leaf it determines is the move a nested chain needs to trade factors, such as `(62, 1, 1, 1)` towards `(6, 6, 6, 6)`, or `(3, 2, 2, 2, 1)` towards `(2, 2, 2, 2, 2)` when the last factor is mapped rather than bound. Sinks are the bind inners of the binds down the chain, then the leaves of the chain's last bound subtree when that subtree has a fixed shape. The chain follows ``ChoiceGraphScheduler/composableNestedBind(under:graph:seenBindFingerprints:)``, so a recursive expansion, whose binds repeat a fingerprint, and a branching dependency, with several nested binds, end it.
    ///
    /// Every bind inner off its target is a source here. Each exchange lifts the generator per probe, so ``ChoiceGraphScheduler/evaluateDispatch(transformation:graph:sequence:gate:scopeCache:graphIsStripped:anyAccepted:)`` holds it back until the source is known to be stalled, as ``RelationQuery`` does for leaf pairs.
    private static func boundExchangeScopes(graph: ChoiceGraph) -> [BoundExchangeScope] {
        var bindInnersByBind: [Int: [Int]] = [:]
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case .chooseBits = node.kind,
                  node.positionRange != nil,
                  node.scopeAnnotation.isDepthControl == false,
                  node.scopeAnnotation.isLaneControl == false,
                  let bindNodeID = node.scopeAnnotation.controllingBindNodeID
            else { continue }
            bindInnersByBind[bindNodeID, default: []].append(nodeID)
        }

        var scopes: [BoundExchangeScope] = []
        for bindNodeID in bindInnersByBind.keys.sorted() {
            let sourceIDs = (bindInnersByBind[bindNodeID] ?? []).filter { isOffTarget($0, graph: graph) }
            guard sourceIDs.isEmpty == false,
                  case let .bind(metadata) = graph.nodes[bindNodeID].kind
            else { continue }

            var sinks: [(leafNodeID: Int, bindNodeID: Int, isBindInner: Bool)] = []
            var seenBindFingerprints: Set<UInt64> = [metadata.fingerprint]
            var current = bindNodeID
            while let nested = ChoiceGraphScheduler.composableNestedBind(
                under: current,
                graph: graph,
                seenBindFingerprints: seenBindFingerprints
            ) {
                seenBindFingerprints.insert(nested.metadata.fingerprint)
                current = nested.nodeID
                for bindInnerID in bindInnersByBind[nested.nodeID] ?? [] {
                    sinks.append((bindInnerID, nested.nodeID, true))
                }
            }
            for leafID in fixedShapeBoundLeaves(of: current, graph: graph) {
                sinks.append((leafID, current, false))
            }

            for sourceID in sourceIDs {
                guard case let .chooseBits(sourceMetadata) = graph.nodes[sourceID].kind else { continue }
                for sink in sinks {
                    guard case let .chooseBits(sinkMetadata) = graph.nodes[sink.leafNodeID].kind,
                          sinkMetadata.typeTag == sourceMetadata.typeTag,
                          sinkMetadata.typeTag.isFloatingPoint == false
                    else { continue }
                    scopes.append(BoundExchangeScope(
                        sourceLeafNodeID: sourceID,
                        sinkLeafNodeID: sink.leafNodeID,
                        sinkBindNodeID: sink.bindNodeID,
                        sinkIsBindInner: sink.isBindInner
                    ))
                }
            }
        }
        return scopes
    }

    /// Whether the leaf sits away from its reduction target, so it has magnitude to give up.
    private static func isOffTarget(_ nodeID: Int, graph: ChoiceGraph) -> Bool {
        guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { return false }
        return metadata.value.bitPattern64 != metadata.value.reductionTarget(in: metadata.validRange)
    }

    /// Returns the value leaves of a bind's bound subtree when that subtree has a fixed shape: no binds, picks, or sequences, so a lift keeps each leaf at the same offset in the bound range, and the sinks stay a handful of scalars rather than every element of a payload.
    private static func fixedShapeBoundLeaves(of bindNodeID: Int, graph: ChoiceGraph) -> [Int] {
        guard case let .bind(metadata) = graph.nodes[bindNodeID].kind,
              graph.nodes[bindNodeID].children.count > metadata.boundChildIndex
        else { return [] }

        var leaves: [Int] = []
        var stack = [graph.nodes[bindNodeID].children[metadata.boundChildIndex]]
        while let nodeID = stack.popLast() {
            let node = graph.nodes[nodeID]
            guard node.positionRange != nil else { continue }
            switch node.kind {
                case .bind, .pick, .sequence:
                    return []
                case .chooseBits:
                    if node.scopeAnnotation.isDepthControl == false,
                       node.scopeAnnotation.isLaneControl == false
                    {
                        leaves.append(nodeID)
                    }
                default:
                    stack.append(contentsOf: node.children.reversed())
            }
        }
        return leaves
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
        guard let firstSinkID = sinkChildIDs.first(where: { graph.nodes[$0].positionRange != nil }) else {
            return []
        }

        var sources: [(nodeID: Int, distance: UInt64)] = []
        for childID in sourceChildIDs {
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

    /// Same-type leaves that currently share a bit pattern, one group per shared value. Skips a group covering every leaf, since it would duplicate the whole type group.
    private static func equalValueSubgroups(of nodeIdentifiers: [Int], graph: ChoiceGraph) -> [[Int]] {
        var nodeIdentifiersByBitPattern: [UInt64: [Int]] = [:]
        for nodeIdentifier in nodeIdentifiers {
            guard case let .chooseBits(metadata) = graph.nodes[nodeIdentifier].kind else {
                continue
            }
            nodeIdentifiersByBitPattern[metadata.value.bitPattern64, default: []].append(nodeIdentifier)
        }
        return nodeIdentifiersByBitPattern.values.filter { matchingNodeIdentifiers in
            matchingNodeIdentifiers.count >= 2 && matchingNodeIdentifiers.count < nodeIdentifiers.count
        }
    }
}
