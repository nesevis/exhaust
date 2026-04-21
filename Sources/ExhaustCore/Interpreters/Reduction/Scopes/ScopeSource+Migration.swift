//
//  ScopeSource+Migration.swift
//  Exhaust
//

// MARK: - Migration Source

/// Emits element migration scopes from earlier sequences to later sequences.
///
/// For each pair of antichain-independent sequences where the source is at an earlier position, emits scopes at geometrically decreasing element counts. Moving elements rightward improves shortlex at earlier positions.
struct MigrationSource: ScopeSource {
    private var candidates: [(sourceSeqID: Int, receiverSeqID: Int, elementNodeIDs: [Int], elementRanges: [ClosedRange<Int>], receiverRange: ClosedRange<Int>, yield: Int, isFullMigration: Bool, sourceParentSeqID: Int?)]
    private var index = 0

    init(graph: ChoiceGraph) {
        var entries: [(sourceSeqID: Int, receiverSeqID: Int, elementNodeIDs: [Int], elementRanges: [ClosedRange<Int>], receiverRange: ClosedRange<Int>, yield: Int, isFullMigration: Bool, sourceParentSeqID: Int?)] = []

        // Find all sequence node pairs where source is earlier than receiver.
        // Lengths use UInt64 throughout to match the framework's length-generator type.
        var sequenceNodes: [(nodeID: Int, positionRange: ClosedRange<Int>, elementCount: UInt64, maxLength: UInt64)] = []
        for node in graph.nodes {
            guard case let .sequence(metadata) = node.kind else { continue }
            guard let range = node.positionRange else { continue }
            let maxLength = metadata.lengthConstraint?.upperBound ?? UInt64.max
            sequenceNodes.append((
                nodeID: node.id,
                positionRange: range,
                elementCount: UInt64(metadata.elementCount),
                maxLength: maxLength
            ))
        }
        sequenceNodes.sort { $0.positionRange.lowerBound < $1.positionRange.lowerBound }

        // For each pair (source earlier, receiver later), check independence and capacity.
        for sourceIndex in 0 ..< sequenceNodes.count {
            let source = sequenceNodes[sourceIndex]
            guard source.elementCount > 0 else { continue }

            for receiverIndex in (sourceIndex + 1) ..< sequenceNodes.count {
                let receiver = sequenceNodes[receiverIndex]
                guard receiver.elementCount < receiver.maxLength else { continue }
                guard graph.areIndependent(source.nodeID, receiver.nodeID) else { continue }
                // Reject containment relationships.
                guard source.positionRange.contains(receiver.positionRange.lowerBound) == false,
                      receiver.positionRange.contains(source.positionRange.lowerBound) == false
                else { continue }

                // Collect source's element node IDs and full extents.
                // Use the sequence's stored child extents so transparent wrapper markers (getSize-bind, transform-bind) move with their value entries — otherwise migration leaves orphan markers and the materializer rejects the candidate.
                let sourceNode = graph.nodes[source.nodeID]
                guard case let .sequence(sourceMetadata) = sourceNode.kind else { continue }
                guard sourceMetadata.childPositionRanges.count == sourceNode.children.count else { continue }
                var elementNodeIDs: [Int] = []
                var elementRanges: [ClosedRange<Int>] = []
                for (childIndex, childID) in sourceNode.children.enumerated() {
                    guard graph.nodes[childID].positionRange != nil else { continue }
                    elementNodeIDs.append(childID)
                    elementRanges.append(sourceMetadata.childPositionRanges[childIndex])
                }

                guard elementNodeIDs.isEmpty == false else { continue }

                // Yield: the position count of the elements being moved.
                // Moving them shortens the source (improves shortlex at earlier positions).
                let totalYield = elementRanges.reduce(0) { $0 + $1.count }

                // Determine whether this is a full migration (all source elements moved).
                let isFullMigration = elementNodeIDs.count == sourceNode.children.count
                let sourceParentSeqID: Int? = if isFullMigration,
                                                 let parentID = sourceNode.parent,
                                                 case .sequence = graph.nodes[parentID].kind
                {
                    parentID
                } else {
                    nil
                }

                // Start with moving ALL elements (most drastic).
                entries.append((
                    sourceSeqID: source.nodeID,
                    receiverSeqID: receiver.nodeID,
                    elementNodeIDs: elementNodeIDs,
                    elementRanges: elementRanges,
                    receiverRange: receiver.positionRange,
                    yield: totalYield,
                    isFullMigration: isFullMigration,
                    sourceParentSeqID: sourceParentSeqID
                ))
            }
        }

        // Sort by yield descending.
        entries.sort { $0.yield > $1.yield }
        candidates = entries
    }

    var peekYield: TransformationYield? {
        guard index < candidates.count else { return nil }
        return TransformationYield(
            structural: candidates[index].yield,
            value: 0,
            slack: .exact,
            estimatedProbes: 1
        )
    }

    mutating func next(lastAccepted _: Bool) -> GraphTransformation? {
        guard index < candidates.count else { return nil }
        let entry = candidates[index]
        index += 1

        let scope = MigrationScope(
            sourceSequenceNodeID: entry.sourceSeqID,
            receiverSequenceNodeID: entry.receiverSeqID,
            elementNodeIDs: entry.elementNodeIDs,
            elementPositionRanges: entry.elementRanges,
            receiverPositionRange: entry.receiverRange
        )

        return GraphTransformation(
            operation: .migrate(scope),
            yield: TransformationYield(
                structural: entry.yield,
                value: 0,
                slack: .exact,
                estimatedProbes: 1
            ),
            precondition: {
                // When migration empties the source entirely and the source's parent is a sequence, the constraint is on the parent's ability to lose a child, not the source's own element count.
                if let parentSeqID = entry.sourceParentSeqID {
                    return .all([
                        .sequenceLengthAboveMinimum(sequenceNodeID: parentSeqID),
                        .nodeActive(entry.receiverSeqID),
                    ])
                }
                return .all([
                    .sequenceLengthAboveMinimum(sequenceNodeID: entry.sourceSeqID),
                    .nodeActive(entry.receiverSeqID),
                ])
            }(),
            postcondition: TransformationPostcondition(
                isStructural: true,
                invalidatesConvergence: [],
                enablesRemoval: []
            )
        )
    }
}
