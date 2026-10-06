/// Streams source/receiver scopes while preparing each source's element extents only once.
///
/// Every receiver for a source has the same structural benefit, so sorting source descriptors by yield is sufficient to preserve the eager builder's priority order. Equal yields retain source position order, and each source visits receivers in position order. Only the next valid scope is buffered; element arrays are shared across that source's emitted scopes.
///
/// The dependency adjacency snapshot excludes mutable graph nodes, so value-only acceptance does not force a graph-node array copy while the cursor remains alive.
///
/// - Complexity: O(V + S log S + C) descriptor preparation and O(S + C + V + E) retained state, where S is the number of sequences and C is their collected child extents. Buffering the first scope and each subsequent scope may scan multiple ineligible pairs. Enumerating every eligible pair still requires O(S²) receiver checks, including dependency reachability costs.
struct MigrationCandidateSource {
    private struct SequenceDescriptor {
        let nodeID: Int
        let positionRange: ClosedRange<Int>
        let canReceive: Bool
    }

    private struct SourceDescriptor {
        let sequenceIndex: Int
        let elementNodeIDs: [Int]
        let elementRanges: [ClosedRange<Int>]
        let yield: Int
        let parentSequenceNodeID: Int?
    }

    private let sequences: [SequenceDescriptor]
    private let sources: [SourceDescriptor]
    private let dependencyAdjacency: [[Int]]
    private var sourceIndex = 0
    private var receiverIndex: Int
    private var pendingTransformation: GraphTransformation?

    /// Collects source payloads before pair enumeration so receiver count does not multiply extent collection or storage.
    init(graph: ChoiceGraph) {
        let sequenceNodes = graph.liveNodeIDs.filter { nodeID in
            guard case .sequence = graph.nodes[nodeID].kind, graph.nodes[nodeID].positionRange != nil else {
                return false
            }
            return true
        }.sorted { first, second in
            graph.nodes[first].positionRange!.lowerBound < graph.nodes[second].positionRange!.lowerBound
        }
        sequences = sequenceNodes.map { nodeID in
            let node = graph.nodes[nodeID]
            guard case let .sequence(metadata) = node.kind else {
                preconditionFailure("Prepared migration node must be a sequence")
            }
            return SequenceDescriptor(
                nodeID: nodeID,
                positionRange: node.positionRange!,
                canReceive: UInt64(metadata.elementCount) < (metadata.lengthConstraint?.upperBound ?? UInt64.max)
            )
        }
        sources = sequenceNodes.enumerated().compactMap { sequenceIndex, nodeID -> SourceDescriptor? in
            let node = graph.nodes[nodeID]
            guard sequenceIndex + 1 < sequenceNodes.count,
                  case let .sequence(metadata) = node.kind,
                  metadata.elementCount > 0,
                  metadata.childPositionRanges.count == node.children.count
            else {
                return nil
            }
            var elementNodeIDs: [Int] = []
            var elementRanges: [ClosedRange<Int>] = []
            for (childIndex, childID) in node.children.enumerated() {
                guard graph.nodes[childID].positionRange != nil else {
                    continue
                }
                elementNodeIDs.append(childID)
                // Stored child extents include transparent wrapper markers that must move with their values.
                elementRanges.append(metadata.childPositionRanges[childIndex])
            }
            guard elementNodeIDs.isEmpty == false else {
                return nil
            }
            let parentSequenceNodeID: Int? = {
                guard elementNodeIDs.count == node.children.count,
                      let parentNodeID = node.parent,
                      case .sequence = graph.nodes[parentNodeID].kind
                else {
                    return nil
                }
                return parentNodeID
            }()
            return SourceDescriptor(
                sequenceIndex: sequenceIndex,
                elementNodeIDs: elementNodeIDs,
                elementRanges: elementRanges,
                yield: elementRanges.reduce(0) { $0 + $1.count },
                parentSequenceNodeID: parentSequenceNodeID
            )
        }.sorted { first, second in
            if first.yield != second.yield {
                return first.yield > second.yield
            }
            return first.sequenceIndex < second.sequenceIndex
        }
        dependencyAdjacency = sources.isEmpty ? [] : graph.dependencyAdjacency
        receiverIndex = (sources.first?.sequenceIndex ?? -1) + 1
        prepareNext()
    }

    /// Searches only far enough to buffer the next valid pair, preserving capacity, containment, and dependency gates.
    private mutating func prepareNext() {
        pendingTransformation = nil
        while sourceIndex < sources.count {
            let source = sources[sourceIndex]
            let sourceSequence = sequences[source.sequenceIndex]
            while receiverIndex < sequences.count {
                let receiver = sequences[receiverIndex]
                receiverIndex += 1
                guard receiver.canReceive,
                      sourceSequence.positionRange.contains(receiver.positionRange.lowerBound) == false,
                      receiver.positionRange.contains(sourceSequence.positionRange.lowerBound) == false,
                      DependencyReachability.isReachable(from: sourceSequence.nodeID, to: receiver.nodeID, adjacency: dependencyAdjacency) == false,
                      DependencyReachability.isReachable(from: receiver.nodeID, to: sourceSequence.nodeID, adjacency: dependencyAdjacency) == false
                else {
                    continue
                }
                pendingTransformation = GraphTransformation(
                    operation: .migrate(MigrationScope(
                        sourceSequenceNodeID: sourceSequence.nodeID,
                        receiverSequenceNodeID: receiver.nodeID,
                        elementNodeIDs: source.elementNodeIDs,
                        elementPositionRanges: source.elementRanges,
                        receiverPositionRange: receiver.positionRange,
                        sourceParentSequenceNodeID: source.parentSequenceNodeID
                    )),
                    priority: DispatchPriority(structuralBenefit: source.yield, valueBenefit: 0, reductionMagnitude: 0, estimatedCost: 1)
                )
                return
            }
            sourceIndex += 1
            guard sourceIndex < sources.count else {
                return
            }
            receiverIndex = sources[sourceIndex].sequenceIndex + 1
        }
    }
}

extension MigrationCandidateSource: CandidateSource {
    var peekPriority: DispatchPriority? {
        pendingTransformation?.priority
    }

    var isValueDependent: Bool {
        false
    }

    var isPermutationSource: Bool {
        false
    }

    mutating func next(lastAccepted _: Bool) -> GraphTransformation? {
        guard let transformation = pendingTransformation else {
            return nil
        }
        prepareNext()
        return transformation
    }
}
