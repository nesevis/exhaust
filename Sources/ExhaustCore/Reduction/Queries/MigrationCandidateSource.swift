/// Streams source/receiver scopes while preparing each source's element extents only once.
///
/// Every receiver for a source has the same structural benefit, so sorting source descriptors by yield is sufficient to preserve descending priority order. Equal yields retain source position order, and each source visits receivers in position order. Only the next valid scope is buffered; element arrays are shared across that source's emitted scopes.
///
/// The dependency cache retains immutable adjacency and only sequence-node results, excluding mutable graph nodes so value-only acceptance does not force a graph-node array copy while the cursor remains alive. Both directions use the complete live sequence domain, including full sequences that can donate but cannot receive.
///
/// - Complexity: O(V + S log S + C) descriptor preparation and O(S + C + V + E) retained state, where S is the number of sequences and C is their collected child extents. Buffering the first scope and each subsequent scope may scan multiple ineligible pairs. Enumerating every eligible pair still requires O(S²) receiver checks. Dependency cache hits are expected O(1); each miss traverses O(V + E), and bounded positive-result retention can cause repeated searches after eviction.
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
    private var dependencyReachability: DependencyReachabilityCache
    private var sourceIndex = 0
    private var receiverIndex: Int
    private var pendingTransformation: GraphTransformation?

    /// Collects source payloads before pair enumeration so receiver count does not multiply extent collection or storage.
    init(graph: ChoiceGraph) {
        let sequenceNodes = graph.liveNodeIDs.compactMap { nodeID -> SequenceDescriptor? in
            let node = graph.nodes[nodeID]
            guard case let .sequence(metadata) = node.kind, let range = node.positionRange else {
                return nil
            }
            return SequenceDescriptor(
                nodeID: nodeID,
                positionRange: range,
                canReceive: UInt64(metadata.elementCount) < (metadata.lengthConstraint?.upperBound ?? UInt64.max)
            )
        }.sorted { $0.positionRange.lowerBound < $1.positionRange.lowerBound }
        sequences = sequenceNodes
        sources = sequenceNodes.enumerated().compactMap { sequenceIndex, descriptor -> SourceDescriptor? in
            let node = graph.nodes[descriptor.nodeID]
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
        dependencyReachability = DependencyReachabilityCache(
            adjacency: sources.isEmpty ? [] : graph.dependencyAdjacency,
            candidates: Set(sequenceNodes.map(\.nodeID))
        )
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
                      dependencyReachability.isReachable(from: sourceSequence.nodeID, to: receiver.nodeID) == false,
                      dependencyReachability.isReachable(from: receiver.nodeID, to: sourceSequence.nodeID) == false
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

    /// Exposes actual searches and retained results for profiling enumeration independently of emitted scopes.
    var dependencyTraversalCount: Int {
        dependencyReachability.traversalCount
    }

    var dependencyCachedSourceCount: Int {
        dependencyReachability.cachedSourceCount
    }

    var dependencyCachedNodeCount: Int {
        dependencyReachability.cachedNodeCount
    }
}

extension MigrationCandidateSource: CandidateSource {
    var isValueDependent: Bool {
        false
    }

    var isPermutationSource: Bool {
        false
    }

    var peekPriority: DispatchPriority? {
        pendingTransformation?.priority
    }

    mutating func next() -> GraphTransformation? {
        guard let transformation = pendingTransformation else {
            return nil
        }
        prepareNext()
        return transformation
    }
}
