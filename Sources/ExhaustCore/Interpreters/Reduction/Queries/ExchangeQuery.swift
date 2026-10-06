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

        let pairCursor = GeneratedRedistributionPairCursor(graph: graph)
        let summary = pairCursor.summary()
        if summary.pairCount > 0 {
            scopes.append(.redistribution(RedistributionScope(cursor: .generated(pairCursor), summary: summary)))
        }

        let groups = tandemGroups(graph: graph)
        if groups.isEmpty == false {
            scopes.append(.tandem(TandemScope(groups: groups)))
        }

        if let relationScope = RelationQuery.build(graph: graph) {
            scopes.append(.relation(relationScope))
        }

        scopes.append(contentsOf: boundExchangeScopes(graph: graph).map { .boundExchange($0) })

        return scopes
    }

    // MARK: - Private Helpers

    /// Prepends field roles only when broad search does not already cover the same leaves, preserving the broad group's existing position.
    private static func tandemGroups(graph: ChoiceGraph) -> [TandemGroup] {
        let broadGroups = typeAndEqualValueGroups(graph: graph)
        // Node lists use ascending IDs: broad groups inherit liveNodeIDs order, and role groups explicitly sort their IDs.
        let broadKeys = Set(broadGroups.map(\.nodeIDs))
        let roleGroups = PositionRelativeQuery.build(graph: graph).filter { broadKeys.contains($0.nodeIDs) == false }
        return (roleGroups + broadGroups).map { group in
            TandemGroup(
                leaves: group.nodeIDs.map { leafEntry(for: $0, graph: graph) },
                typeTag: group.typeTag
            )
        }
    }

    /// Orders broad type groups and equal-value subgroups by position, keeping the broader group first when their positions coincide.
    private static func typeAndEqualValueGroups(graph: ChoiceGraph) -> [QueryHelpers.LeafGroup] {
        var leafGroups: [TypeTag: [Int]] = [:]
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else { continue }
            if node.scopeAnnotation.isDepthControl || node.scopeAnnotation.isLaneControl { continue }
            leafGroups[metadata.typeTag, default: []].append(nodeID)
        }

        var groups: [QueryHelpers.LeafGroup] = []
        for (tag, nodeIdentifiers) in leafGroups where nodeIdentifiers.count >= 2 {
            groups.append(QueryHelpers.LeafGroup(typeTag: tag, nodeIDs: nodeIdentifiers))
            for matchingNodeIdentifiers in equalValueSubgroups(of: nodeIdentifiers, graph: graph) {
                groups.append(QueryHelpers.LeafGroup(typeTag: tag, nodeIDs: matchingNodeIdentifiers))
            }
        }

        // Dictionary iteration order varies with the per-process hash seed. The broader type group precedes an equal-value subgroup at the same position so the existing search order remains first.
        groups.sort { groupA, groupB in
            let positionA = groupA.position(in: graph)
            let positionB = groupB.position(in: graph)
            if positionA != positionB {
                return positionA < positionB
            }
            return groupA.nodeIDs.count > groupB.nodeIDs.count
        }
        return groups
    }

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
    /// Lowering an outer bind inner while raising a leaf it determines is the move a nested chain needs to trade factors, such as `(62, 1, 1, 1)` towards `(6, 6, 6, 6)`, or `(3, 2, 2, 2, 1)` towards `(2, 2, 2, 2, 2)` when the last factor is mapped rather than bound. Sinks are the bind inners of the binds down the chain, then the leaves of the chain's last bound subtree when that subtree has a fixed shape. The chain follows ``ChoiceGraph/composableNestedBind(under:seenBindFingerprints:)``, so a recursive expansion, whose binds repeat a fingerprint, and a branching dependency, with several nested binds, end it.
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
            let sourceIDs = (bindInnersByBind[bindNodeID] ?? []).filter { QueryHelpers.isOffTarget($0, graph: graph) }
            guard sourceIDs.isEmpty == false,
                  case let .bind(metadata) = graph.nodes[bindNodeID].kind
            else { continue }

            var sinks: [(leafNodeID: Int, location: SinkLocation)] = []
            var seenBindFingerprints: Set<UInt64> = [metadata.fingerprint]
            var current = bindNodeID
            while let nested = graph.composableNestedBind(
                under: current,
                seenBindFingerprints: seenBindFingerprints
            ) {
                seenBindFingerprints.insert(nested.metadata.fingerprint)
                current = nested.nodeID
                for bindInnerID in bindInnersByBind[nested.nodeID] ?? [] {
                    sinks.append((bindInnerID, .bindInner(bindNodeID: nested.nodeID)))
                }
            }
            for leafID in fixedShapeBoundLeaves(of: current, graph: graph) {
                sinks.append((leafID, .boundLeaf(bindNodeID: current)))
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
                        sinkLocation: sink.location
                    ))
                }
            }
        }
        return scopes
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
