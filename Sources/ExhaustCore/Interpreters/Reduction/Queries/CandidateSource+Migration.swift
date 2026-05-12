//
//  CandidateSource+Migration.swift
//  Exhaust
//

// MARK: - Builder Functions

extension CandidateSourceBuilder {
    /// Constructs migration scopes from type-compatible sequence node pairs in the graph. For each pair where the source has elements and the receiver has capacity, builds a ``MigrationScope`` that moves elements from the earlier sequence to the later one. Sorted by yield descending so the highest-impact migrations are tried first.
    static func buildMigrationCandidates(graph: ChoiceGraph) -> [GraphTransformation] {
        var entries: [(scope: MigrationScope, yield: Int)] = []

        // Find all sequence node pairs where source is earlier than receiver.
        // Lengths use UInt64 throughout to match the framework's length-generator type.
        var sequenceNodes: [(nodeID: Int, positionRange: ClosedRange<Int>, elementCount: UInt64, maxLength: UInt64)] = []
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .sequence(metadata) = node.kind else { continue }
            guard let range = node.positionRange else { continue }
            let maxLength = metadata.lengthConstraint?.upperBound ?? UInt64.max
            sequenceNodes.append((
                nodeID: nodeID,
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
                let sourceParentSeqID: Int? = {
                    guard isFullMigration,
                          let parentID = sourceNode.parent,
                          case .sequence = graph.nodes[parentID].kind
                    else { return nil }
                    return parentID
                }()

                let scope = MigrationScope(
                    sourceSequenceNodeID: source.nodeID,
                    receiverSequenceNodeID: receiver.nodeID,
                    elementNodeIDs: elementNodeIDs,
                    elementPositionRanges: elementRanges,
                    receiverPositionRange: receiver.positionRange,
                    sourceParentSequenceNodeID: sourceParentSeqID
                )

                entries.append((scope: scope, yield: totalYield))
            }
        }

        // Sort by yield descending.
        entries.sort { $0.yield > $1.yield }

        return entries.map { entry in
            GraphTransformation(
                operation: .migrate(entry.scope),
                priority: DispatchPriority(
                    structuralBenefit: entry.yield,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: 1
                )
            )
        }
    }
}
