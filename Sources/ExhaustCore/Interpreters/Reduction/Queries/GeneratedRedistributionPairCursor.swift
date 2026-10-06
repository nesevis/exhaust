/// Streams adjacent homogeneous pairs, cross-zip homogeneous pairs, then compatibility-edge pairs in their original discovery order.
///
/// Each homogeneous sequence is prepared once, including its first active sink and stable distance-ranked source prefix. Zip slots share those descriptors, so pairing two slots does not recollect or sort either sequence. The leaf snapshot retains annotations and positions without retaining graph nodes.
///
/// - Complexity: O(V + C + A · W) retained state, where V is the node count, C is homogeneous direct leaf membership, A is zip-child membership, and W is compatibility lookahead. Pair enumeration can still be quadratic in zip slot count, but never stores that cross product.
struct GeneratedRedistributionPairCursor: Sendable {
    private struct Leaf: Sendable {
        let entry: LeafEntry
        let tag: TypeTag
        let position: Int
        let distance: UInt64
        let controllingBindNodeID: Int?
        let isEdgeEligible: Bool
    }

    private struct HomogeneousGroup: Sendable {
        let tag: TypeTag
        let minimumPosition: Int
        let leaves: [Leaf]
        let sources: [Leaf]
        let firstSink: LeafEntry?
    }

    private let leavesByNodeID: [Leaf?]
    private let adjacentGroups: [HomogeneousGroup]
    private let zipGroups: [[HomogeneousGroup]]
    private var edges: TypeCompatibilityCursor
    private var adjacentGroup = 0
    private var adjacentSource = 0
    private var zipIndex = 0
    private var firstGroup = 0
    private var secondGroup = 1
    private var sourceIndex = 0

    /// Captures live leaf roles and reusable homogeneous groups before any pair enumeration.
    init(graph: ChoiceGraph) {
        let leaves = graph.nodes.map { node -> Leaf? in
            guard let range = node.positionRange,
                  case let .chooseBits(metadata) = node.kind
            else {
                return nil
            }
            let annotation = node.scopeAnnotation
            return Leaf(
                entry: Self.leafEntry(for: node.id, graph: graph),
                tag: metadata.typeTag,
                position: range.lowerBound,
                distance: QueryHelpers.reductionDistance(metadata),
                controllingBindNodeID: annotation.controllingBindNodeID,
                isEdgeEligible: annotation.isDepthControl == false && annotation.isLaneControl == false
            )
        }
        leavesByNodeID = leaves
        var groupsByNodeID: [Int: HomogeneousGroup] = [:]
        var adjacent: [HomogeneousGroup] = []
        for nodeID in graph.liveNodeIDs {
            guard case let .sequence(metadata) = graph.nodes[nodeID].kind,
                  let tag = metadata.elementTypeTag
            else {
                continue
            }
            let group = Self.prepareGroup(nodeID: nodeID, tag: tag, leaves: leaves, graph: graph)
            groupsByNodeID[nodeID] = group
            if tag != .depthControl, tag != .laneControl, group.leaves.count >= 2 {
                adjacent.append(group)
            }
        }
        var zips: [[HomogeneousGroup]] = []
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case .zip = node.kind, node.children.count >= 2 else {
                continue
            }
            var groups: [HomogeneousGroup] = []
            for childID in node.children {
                guard let sequenceID = QueryHelpers.findSequenceBeneath(childID, graph: graph),
                      case let .sequence(metadata) = graph.nodes[sequenceID].kind,
                      let tag = metadata.elementTypeTag
                else {
                    continue
                }
                if let group = groupsByNodeID[sequenceID] {
                    groups.append(group)
                } else {
                    // Inactive sequences can be found beneath wrappers; they participate in discovery but have no live sources or sinks.
                    let group = Self.prepareGroup(nodeID: sequenceID, tag: tag, leaves: leaves, graph: graph)
                    groupsByNodeID[sequenceID] = group
                    groups.append(group)
                }
            }
            if groups.count >= 2 {
                zips.append(groups)
            }
        }
        adjacentGroups = adjacent
        zipGroups = zips
        edges = TypeCompatibilityCursor(graph: graph)
    }

    /// Counts pairs and measures scheduling distance in one allocation-free pass over a copy of the cursor.
    ///
    /// Scheduling needs exact metadata for the entire scope before dispatch. This pass does not change the encoder's enumeration position or retain any of the emitted pairs.
    func summary() -> RedistributionPairSummary {
        var cursor = self
        var count = 0
        var maximumDistance: UInt64 = 0
        while let pair = cursor.next(lastAccepted: false) {
            count += 1
            maximumDistance = max(maximumDistance, leavesByNodeID[pair.source.nodeID]?.distance ?? 0)
        }
        return RedistributionPairSummary(pairCount: count, maximumSourceDistance: maximumDistance)
    }

    /// Retains only the cross-slot source budget, preserving stable distance ties from the sequence's original child order.
    private static func prepareGroup(nodeID: Int, tag: TypeTag, leaves: [Leaf?], graph: ChoiceGraph) -> HomogeneousGroup {
        let node = graph.nodes[nodeID]
        let members = node.children.compactMap { leaves[$0] }
        var sources = BoundedSortedBuffer<Leaf>(limit: GraphRedistributionEncoder.maxPairsPerScope)
        for member in members where member.distance > 0 {
            sources.insert(member) { $0.distance > $1.distance }
        }
        let firstSink = node.children.first { graph.nodes[$0].positionRange != nil }.map {
            leafEntry(for: $0, graph: graph)
        }
        return HomogeneousGroup(
            tag: tag,
            minimumPosition: node.positionRange?.lowerBound ?? Int.max,
            leaves: members.sorted { $0.position < $1.position },
            sources: sources.elements,
            firstSink: firstSink
        )
    }

    /// Keeps the next active leaf as the sink even if that leaf is already at its target.
    private mutating func nextAdjacentPair() -> RedistributionPair? {
        while adjacentGroup < adjacentGroups.count {
            let group = adjacentGroups[adjacentGroup]
            guard adjacentSource + 1 < group.leaves.count else {
                adjacentGroup += 1
                adjacentSource = 0
                continue
            }
            let source = group.leaves[adjacentSource]
            let sink = group.leaves[adjacentSource + 1]
            adjacentSource += 1
            guard source.distance > 0 else {
                continue
            }
            return RedistributionPair(source: source.entry, sink: sink.entry, sourceTag: group.tag, sinkTag: group.tag)
        }
        return nil
    }

    /// Visits slot pairs in child order while orienting the source by the sequences' positions, as the eager builder did.
    private mutating func nextHomogeneousZipPair() -> RedistributionPair? {
        while zipIndex < zipGroups.count {
            let groups = zipGroups[zipIndex]
            guard firstGroup + 1 < groups.count else {
                zipIndex += 1
                firstGroup = 0
                secondGroup = 1
                sourceIndex = 0
                continue
            }
            guard secondGroup < groups.count else {
                firstGroup += 1
                secondGroup = firstGroup + 1
                sourceIndex = 0
                continue
            }
            let first = groups[firstGroup]
            let second = groups[secondGroup]
            let (source, sink) = first.minimumPosition < second.minimumPosition ? (first, second) : (second, first)
            guard first.tag == second.tag,
                  let sinkEntry = sink.firstSink,
                  sourceIndex < source.sources.count
            else {
                secondGroup += 1
                sourceIndex = 0
                continue
            }
            let sourceEntry = source.sources[sourceIndex].entry
            sourceIndex += 1
            return RedistributionPair(source: sourceEntry, sink: sinkEntry, sourceTag: first.tag, sinkTag: first.tag)
        }
        return nil
    }

    /// Excludes cross-bind and control-leaf edges before choosing the earlier off-target leaf as the source.
    private mutating func nextCompatibilityPair() -> RedistributionPair? {
        while let edge = edges.next(lastAccepted: false) {
            guard let first = leavesByNodeID[edge.nodeA],
                  let second = leavesByNodeID[edge.nodeB],
                  first.controllingBindNodeID == second.controllingBindNodeID,
                  first.isEdgeEligible,
                  second.isEdgeEligible,
                  first.position != second.position
            else {
                continue
            }
            let (source, sink) = first.position < second.position ? (first, second) : (second, first)
            guard source.distance > 0 else {
                continue
            }
            return RedistributionPair(source: source.entry, sink: sink.entry, sourceTag: source.tag, sinkTag: sink.tag)
        }
        return nil
    }

    private static func leafEntry(for nodeID: Int, graph: ChoiceGraph) -> LeafEntry {
        let annotation = graph.nodes[nodeID].scopeAnnotation
        return LeafEntry(nodeID: nodeID, mayReshapeOnAcceptance: annotation.isBindInner, bindDepth: annotation.controllingBindDepth)
    }
}

extension GeneratedRedistributionPairCursor: ScopeCursor {
    mutating func next(lastAccepted _: Bool) -> RedistributionPair? {
        nextAdjacentPair() ?? nextHomogeneousZipPair() ?? nextCompatibilityPair()
    }
}
