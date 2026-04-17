//
//  ExchangeScopeQuery.swift
//  Exhaust
//

// MARK: - Exchange Scope Query

/// Static scope builder for exchange operations (redistribution and tandem lockstep reduction).
///
/// Replaces the former `ChoiceGraph.exchangeScopes()` instance method. Callers that also need minimization scopes should build ``ScopeQueryHelpers/buildInnerDescendantToBind(graph:)`` once and pass it to both ``build(graph:innerDescendantToBind:)`` and ``MinimizationScopeQuery/build(graph:innerDescendantToBind:)``.
enum ExchangeScopeQuery {
    /// Computes exchange scopes from type-compatibility edges, homogeneous group descriptors, and leaf groupings.
    ///
    /// Redistribution pairs any two type-compatible leaves where one is not at its reduction target. The source is zeroed and the receiver absorbs the delta. Homogeneous sequences (``SequenceMetadata/elementTypeTag`` non-nil) generate bounded pairs directly in O(C log C) without materializing type-compatibility edges. Heterogeneous sequences and mixed-type cross-zip pairs fall back to the precomputed edge set.
    ///
    /// - Parameters:
    ///   - graph: The current choice graph.
    ///   - innerDescendantToBind: Precomputed bind-inner index from ``ScopeQueryHelpers/buildInnerDescendantToBind(graph:)``. Pass a shared instance when also building minimization scopes so the same dictionary is reused across both families.
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

            // The source must be at an earlier position than the receiver
            // so that zeroing the source produces a shortlex-smaller candidate
            // (the first pairwise difference favors the candidate).
            let positionA = graph.nodes[edge.nodeA].positionRange?.lowerBound ?? Int.max
            let positionB = graph.nodes[edge.nodeB].positionRange?.lowerBound ?? Int.max

            // A is earlier — A can be the source (zeroed), B receives.
            if positionA < positionB, distanceA > 0 {
                pairs.append(RedistributionPair(
                    source: ScopeQueryHelpers.makeLeafEntry(edge.nodeA, innerDescendantToBind: innerDescendantToBind),
                    sink: ScopeQueryHelpers.makeLeafEntry(edge.nodeB, innerDescendantToBind: innerDescendantToBind),
                    sourceTag: metadataA.typeTag,
                    sinkTag: metadataB.typeTag
                ))
            }
            // B is earlier — B can be the source (zeroed), A receives.
            if positionB < positionA, distanceB > 0 {
                pairs.append(RedistributionPair(
                    source: ScopeQueryHelpers.makeLeafEntry(edge.nodeB, innerDescendantToBind: innerDescendantToBind),
                    sink: ScopeQueryHelpers.makeLeafEntry(edge.nodeA, innerDescendantToBind: innerDescendantToBind),
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
        for node in graph.nodes {
            guard case let .chooseBits(metadata) = node.kind else { continue }
            guard node.positionRange != nil else { continue }
            leafGroups[metadata.typeTag, default: []].append(node.id)
        }
        let tandemGroups = leafGroups.compactMap { tag, leafIDs -> TandemGroup? in
            guard leafIDs.count >= 2 else { return nil }
            let entries = leafIDs.map {
                ScopeQueryHelpers.makeLeafEntry($0, innerDescendantToBind: innerDescendantToBind)
            }
            return TandemGroup(leaves: entries, typeTag: tag)
        }
        if tandemGroups.isEmpty == false {
            scopes.append(.tandem(TandemScope(groups: tandemGroups)))
        }

        return scopes
    }

    /// Convenience overload that builds ``ScopeQueryHelpers/buildInnerDescendantToBind(graph:)`` on the caller's behalf. Prefer the primary overload when also building minimization scopes so the index is computed once and shared.
    static func build(graph: ChoiceGraph) -> [ExchangeScope] {
        build(
            graph: graph,
            innerDescendantToBind: ScopeQueryHelpers.buildInnerDescendantToBind(graph: graph)
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

        // Intra-sequence: each homogeneous sequence produces source-sink
        // pairs among its own leaves.
        for parentNode in graph.nodes {
            guard parentNode.positionRange != nil else { continue }
            guard case let .sequence(seqMetadata) = parentNode.kind else { continue }
            guard let tag = seqMetadata.elementTypeTag else { continue }

            let intraPairs = pairsFromHomogeneousLeaves(
                childIDs: parentNode.children,
                tag: tag,
                graph: graph,
                innerDescendantToBind: innerDescendantToBind
            )
            pairs.append(contentsOf: intraPairs)
        }

        // Cross-zip: for each zip, find pairs of homogeneous sequence
        // children with matching type tags. Generate cross-group
        // source-sink pairs where the source comes from the
        // earlier-positioned group.
        for zipNode in graph.nodes {
            guard case .zip = zipNode.kind else { continue }
            guard zipNode.positionRange != nil else { continue }
            guard zipNode.children.count >= 2 else { continue }

            // Collect homogeneous sequence children with their tags.
            var homogeneousChildren: [(sequenceNodeID: Int, tag: TypeTag, children: [Int], minPosition: Int)] = []
            for childID in zipNode.children {
                guard let seqID = ScopeQueryHelpers.findSequenceBeneath(childID, graph: graph) else { continue }
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

                    // The earlier-positioned group provides sources,
                    // the later group provides sinks.
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
    /// Sorts leaves by position, then for each source (distance from target > 0) pairs it with the first later-position leaf. Produces at most C-1 pairs for C leaves.
    private static func pairsFromHomogeneousLeaves(
        childIDs: [Int],
        tag: TypeTag,
        graph: ChoiceGraph,
        innerDescendantToBind: [Int: Int]
    ) -> [RedistributionPair] {
        // Collect leaves with position and distance.
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

        // Sort by position for the shortlex ordering constraint.
        leaves.sort { $0.position < $1.position }

        var pairs: [RedistributionPair] = []
        for index in 0 ..< leaves.count {
            guard leaves[index].distance > 0 else { continue }
            // Pair with the first later-position leaf.
            if index + 1 < leaves.count {
                pairs.append(RedistributionPair(
                    source: ScopeQueryHelpers.makeLeafEntry(leaves[index].nodeID, innerDescendantToBind: innerDescendantToBind),
                    sink: ScopeQueryHelpers.makeLeafEntry(leaves[index + 1].nodeID, innerDescendantToBind: innerDescendantToBind),
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
        guard let firstSinkID = sinkChildIDs.first else { return [] }
        guard graph.nodes[firstSinkID].positionRange != nil else { return [] }

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

        // Take sources with the largest distance.
        sources.sort { $0.distance > $1.distance }
        let budget = min(sources.count, GraphRedistributionEncoder.maxPairsPerScope)

        return sources.prefix(budget).map { source in
            RedistributionPair(
                source: ScopeQueryHelpers.makeLeafEntry(source.nodeID, innerDescendantToBind: innerDescendantToBind),
                sink: ScopeQueryHelpers.makeLeafEntry(firstSinkID, innerDescendantToBind: innerDescendantToBind),
                sourceTag: tag,
                sinkTag: tag
            )
        }
    }
}
