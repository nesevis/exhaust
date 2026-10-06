@testable import ExhaustCore

/// Preserves the pre-cursor edge and redistribution algorithms as independent order and eligibility oracles.
enum EagerExchangeReference {
    /// Retains original homogeneous-first discovery and edge eligibility independently of the generated cursor.
    static func redistributionPairs(graph: ChoiceGraph) -> [RedistributionPair] {
        var pairs: [RedistributionPair] = []
        pairs.append(contentsOf: homogeneousRedistributionPairs(graph: graph))
        for edge in typeCompatibilityEdges(graph: graph) {
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

            let distanceA = QueryHelpers.reductionDistance(metadataA)
            let distanceB = QueryHelpers.reductionDistance(metadataB)

            guard distanceA > 0 || distanceB > 0 else {
                continue
            }

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
        return pairs
    }

    /// Preserves adjacent-sequence discovery before cross-zip homogeneous pairs.
    private static func homogeneousRedistributionPairs(
        graph: ChoiceGraph
    ) -> [RedistributionPair] {
        var pairs: [RedistributionPair] = []

        for parentNodeID in graph.liveNodeIDs {
            let parentNode = graph.nodes[parentNodeID]
            guard case let .sequence(sequenceMetadata) = parentNode.kind else {
                continue
            }
            guard let tag = sequenceMetadata.elementTypeTag else {
                continue
            }
            if case .depthControl = tag {
                continue
            }
            if case .laneControl = tag {
                continue
            }

            let intraPairs = pairsFromHomogeneousLeaves(
                childIDs: parentNode.children,
                tag: tag,
                graph: graph
            )
            pairs.append(contentsOf: intraPairs)
        }

        for zipNodeID in graph.liveNodeIDs {
            let zipNode = graph.nodes[zipNodeID]
            guard case .zip = zipNode.kind else {
                continue
            }
            guard zipNode.children.count >= 2 else {
                continue
            }

            var homogeneousChildren: [(sequenceNodeID: Int, tag: TypeTag, children: [Int], minPosition: Int)] = []
            for childID in zipNode.children {
                guard let sequenceID = QueryHelpers.findSequenceBeneath(childID, graph: graph) else {
                    continue
                }
                guard case let .sequence(sequenceMetadata) = graph.nodes[sequenceID].kind else {
                    continue
                }
                guard let tag = sequenceMetadata.elementTypeTag else {
                    continue
                }
                let minimumPosition = graph.nodes[sequenceID].positionRange?.lowerBound ?? Int.max
                homogeneousChildren.append((
                    sequenceNodeID: sequenceID,
                    tag: tag,
                    children: graph.nodes[sequenceID].children,
                    minPosition: minimumPosition
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

    /// Keeps target-converged leaves as adjacent sinks while skipping them as sources.
    private static func pairsFromHomogeneousLeaves(
        childIDs: [Int],
        tag: TypeTag,
        graph: ChoiceGraph
    ) -> [RedistributionPair] {
        var leaves: [(nodeID: Int, position: Int, distance: UInt64)] = []
        for childID in childIDs {
            guard case let .chooseBits(metadata) = graph.nodes[childID].kind else {
                continue
            }
            guard let range = graph.nodes[childID].positionRange else {
                continue
            }
            let distance = QueryHelpers.reductionDistance(metadata)
            leaves.append((nodeID: childID, position: range.lowerBound, distance: distance))
        }
        guard leaves.count >= 2 else {
            return []
        }

        leaves.sort { $0.position < $1.position }

        var pairs: [RedistributionPair] = []
        for index in 0 ..< leaves.count {
            guard leaves[index].distance > 0 else {
                continue
            }
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

    /// Sorts the complete source set before taking its prefix, providing an oracle for bounded source selection.
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
            guard case let .chooseBits(metadata) = graph.nodes[childID].kind else {
                continue
            }
            guard graph.nodes[childID].positionRange != nil else {
                continue
            }
            let distance = QueryHelpers.reductionDistance(metadata)
            guard distance > 0 else {
                continue
            }
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

    private static func leafEntry(for nodeID: Int, graph: ChoiceGraph) -> LeafEntry {
        let annotation = graph.nodes[nodeID].scopeAnnotation
        return LeafEntry(
            nodeID: nodeID,
            mayReshapeOnAcceptance: annotation.isBindInner,
            bindDepth: annotation.controllingBindDepth
        )
    }
}

extension EagerExchangeReference {
    /// Retains the original full edge construction, including sliding sibling windows and the inclusive first-side zip cutoff.
    static func typeCompatibilityEdges(graph: ChoiceGraph) -> [TypeCompatibilityEdge] {
        let nodes = graph.nodes
        let liveNodeIDs = graph.liveNodeIDs
        var edges: [TypeCompatibilityEdge] = []

        // Pass 1: chooseBits siblings under each heterogeneous sequence parent.
        // Homogeneous sequences (elementTypeTag != nil) are handled by homogeneousRedistributionPairs() in O(C log C) instead of O(C²).
        for parentNodeID in liveNodeIDs {
            let parentNode = nodes[parentNodeID]
            guard case let .sequence(sequenceMetadata) = parentNode.kind else {
                continue
            }
            guard sequenceMetadata.elementTypeTag == nil else {
                continue
            }

            var siblings: [(nodeID: Int, tag: TypeTag)] = []
            siblings.reserveCapacity(parentNode.children.count)
            for childID in parentNode.children {
                guard childID < nodes.count else {
                    continue
                }
                let child = nodes[childID]
                guard child.positionRange != nil else {
                    continue
                }
                guard case let .chooseBits(metadata) = child.kind else {
                    continue
                }
                siblings.append((nodeID: childID, tag: metadata.typeTag))
            }
            guard siblings.count >= 2 else {
                continue
            }

            var indexA = 0
            while indexA < siblings.count {
                let limit = min(siblings.count, indexA + 1 + SchedulerTuning.maxPairLookahead)
                var indexB = indexA + 1
                while indexB < limit {
                    let tagA = siblings[indexA].tag
                    let tagB = siblings[indexB].tag
                    let sharedTag: TypeTag? = (tagA == tagB) ? tagA : nil
                    edges.append(TypeCompatibilityEdge(
                        nodeA: siblings[indexA].nodeID,
                        nodeB: siblings[indexB].nodeID,
                        typeTag: sharedTag
                    ))
                    indexB += 1
                }
                indexA += 1
            }
        }

        // Pass 2: chooseBits descendants across different children of each zip parent.
        // Tuple slots are simultaneously chosen, so cross-slot value pairs are semantically meaningful redistribution candidates (Bound5's d + e coupling). Within-slot pairs are skipped here because they were (or will be) generated by pass 1 against the appropriate sequence parent inside that slot.
        for zipNodeID in liveNodeIDs {
            let zipNode = nodes[zipNodeID]
            guard case .zip = zipNode.kind else {
                continue
            }
            guard zipNode.children.count >= 2 else {
                continue
            }

            // Collect leaves per zip child via a containment-tree walk.
            // Track each child's homogeneous type tag (if any) so that cross-slot pairs between two homogeneous groups of the same type can be deferred to homogeneousRedistributionPairs().
            var perChildLeaves: [[(nodeID: Int, tag: TypeTag)]] = []
            var perChildHomogeneousTag: [TypeTag?] = []
            perChildLeaves.reserveCapacity(zipNode.children.count)
            perChildHomogeneousTag.reserveCapacity(zipNode.children.count)
            for childID in zipNode.children {
                var leaves: [(nodeID: Int, tag: TypeTag)] = []
                collectChooseBitsDescendants(rootID: childID, graph: graph, into: &leaves)
                perChildLeaves.append(leaves)
                let childNode = nodes[childID]
                if case let .sequence(sequenceMetadata) = childNode.kind {
                    perChildHomogeneousTag.append(sequenceMetadata.elementTypeTag)
                } else {
                    perChildHomogeneousTag.append(nil)
                }
            }

            // Pair leaves across different child groups only. Skip pairs between two homogeneous groups of the same type — those are handled by homogeneousRedistributionPairs() in O(C) instead of O(L_i * L_j).
            var groupA = 0
            while groupA < perChildLeaves.count {
                var groupB = groupA + 1
                while groupB < perChildLeaves.count {
                    let tagA = perChildHomogeneousTag[groupA]
                    let tagB = perChildHomogeneousTag[groupB]
                    if let tagA, let tagB, tagA == tagB {
                        groupB += 1
                        continue
                    }
                    let leafLimit = SchedulerTuning.maxPairLookahead
                    for (indexA, leafA) in perChildLeaves[groupA].enumerated() {
                        let secondGroupLimit = min(perChildLeaves[groupB].count, leafLimit)
                        for indexB in 0 ..< secondGroupLimit {
                            let leafB = perChildLeaves[groupB][indexB]
                            let sharedTag: TypeTag? = (leafA.tag == leafB.tag) ? leafA.tag : nil
                            edges.append(TypeCompatibilityEdge(
                                nodeA: leafA.nodeID,
                                nodeB: leafB.nodeID,
                                typeTag: sharedTag
                            ))
                        }
                        if indexA >= leafLimit {
                            break
                        }
                    }
                    groupB += 1
                }
                groupA += 1
            }
        }

        return edges
    }

    /// Collects the entire active subtree so the oracle does not share the production cursor's prefix memoization.
    private static func collectChooseBitsDescendants(
        rootID: Int,
        graph: ChoiceGraph,
        into result: inout [(nodeID: Int, tag: TypeTag)]
    ) {
        let nodes = graph.nodes
        guard rootID < nodes.count else {
            return
        }
        let node = nodes[rootID]
        guard node.positionRange != nil else {
            return
        }
        if case let .chooseBits(metadata) = node.kind {
            result.append((nodeID: rootID, tag: metadata.typeTag))
        }
        for childID in node.children {
            collectChooseBitsDescendants(rootID: childID, graph: graph, into: &result)
        }
    }
}

extension ChoiceGraph {
    /// Materializes all eligible sequence-sibling and zip cross-slot edges on each access. Production consumers use ``TypeCompatibilityCursor`` to avoid retaining the cross products.
    var typeCompatibilityEdges: [TypeCompatibilityEdge] {
        var cursor = TypeCompatibilityCursor(graph: self)
        var edges: [TypeCompatibilityEdge] = []
        edges.reserveCapacity(cursor.edgeCount)
        while let edge = cursor.next() {
            edges.append(edge)
        }
        return edges
    }
}

extension GraphRedistributionEncoder {
    /// Exercises arbitrary reference pairs through the same cursor consumer as production.
    mutating func startRedistribution(pairs: [RedistributionPair], graph: ChoiceGraph) {
        startRedistribution(cursor: BufferedScopeCursor(pairs), graph: graph)
    }
}
