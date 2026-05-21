/// Drives ``TypeTag/laneControl`` values to zero and canonicalizes element order so all prefix commands are contiguous at the front.
///
/// Each probe is a binary decision: set one lane marker to zero, then stable-partition the sequence elements so all prefix (lane 0) elements precede all concurrent elements, preserving relative order within each group. The candidate presented to the property closure always has the canonical `[0, 0, 0, X, Y, X]` layout.
///
/// Leaves are processed front-to-back so the prefix grows from the beginning of the command sequence.
struct GraphLaneCollapseEncoder: GraphEncoder {
    let name: EncoderName = .laneCollapse

    private var leaves: [LaneLeaf] = []
    private var leafIndex: Int = 0
    private var currentSequence: ChoiceSequence = []
    private var elements: [SequenceElement] = []

    mutating func start(scope: EncoderInput) {
        guard case let .minimize(.laneCollapse(laneScope)) = scope.transformation.operation else {
            leaves = []
            leafIndex = 0
            return
        }
        currentSequence = scope.baseSequence

        elements = collectSequenceElements(graph: scope.graph)

        leaves = laneScope.leaves.compactMap { entry in
            let leafNodeID = entry.nodeID
            guard let leafRange = scope.graph.nodes[leafNodeID].positionRange else { return nil }
            let leafPosition = leafRange.lowerBound

            guard let elementIndex = elements.firstIndex(where: { $0.range.contains(leafPosition) }) else {
                return nil
            }

            return LaneLeaf(
                leafNodeID: leafNodeID,
                leafPosition: leafPosition,
                elementIndex: elementIndex
            )
        }

        leaves.sort { $0.leafPosition < $1.leafPosition }
        leafIndex = 0
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        if lastAccepted, leafIndex > 0 {
            currentSequence = candidate
            elements = remapElements(sequence: currentSequence, oldElements: elements)
        }

        while leafIndex < leaves.count {
            let leaf = leaves[leafIndex]
            leafIndex += 1

            guard leaf.leafPosition < currentSequence.count else { continue }
            guard case let .value(entry) = currentSequence[leaf.leafPosition] else { continue }
            guard entry.choice.bitPattern64 != 0 else { continue }

            candidate = currentSequence

            let zeroValue = ChoiceValue(UInt64(0), tag: entry.choice.tag)
            candidate[leaf.leafPosition] = .value(ChoiceSequenceValue.Value(
                choice: zeroValue,
                validRange: entry.validRange,
                isRangeExplicit: entry.isRangeExplicit
            ))

            candidate = stablePartitionByPrefix(candidate, elements: elements, laneControlPositions: collectLaneControlPositions(in: candidate, elements: elements))

            return .sequenceReordered
        }
        return nil
    }
}

// MARK: - Types

private struct LaneLeaf {
    let leafNodeID: Int
    let leafPosition: Int
    let elementIndex: Int
}

private struct SequenceElement {
    let range: ClosedRange<Int>
}

// MARK: - Element Collection

/// Finds the outermost `.sequence` node in the graph and collects the position range of each child element.
private func collectSequenceElements(graph: ChoiceGraph) -> [SequenceElement] {
    for nodeID in graph.liveNodeIDs {
        let node = graph.nodes[nodeID]
        if case let .sequence(metadata) = node.kind {
            return metadata.childPositionRanges.map { SequenceElement(range: $0) }
        }
    }
    return []
}

/// After a sequence reorder, element ranges may have shifted. Reconstruct from the old elements' sizes applied in order to the current sequence.
private func remapElements(sequence: ChoiceSequence, oldElements: [SequenceElement]) -> [SequenceElement] {
    var result: [SequenceElement] = []
    var position = oldElements.first?.range.lowerBound ?? 0
    for old in oldElements {
        let size = old.range.count
        if position + size - 1 < sequence.count {
            result.append(SequenceElement(range: position ... (position + size - 1)))
        }
        position += size
    }
    return result
}

// MARK: - Lane Control Detection

/// Returns the laneControl value for each element by scanning for the `.laneControl`-tagged entry within each element's range.
private func collectLaneControlPositions(
    in sequence: ChoiceSequence,
    elements: [SequenceElement]
) -> [UInt64] {
    elements.map { element in
        for position in element.range {
            guard position < sequence.count else { break }
            if case let .value(entry) = sequence[position],
               case .laneControl = entry.choice.tag
            {
                return entry.choice.bitPattern64
            }
        }
        return UInt64.max
    }
}

// MARK: - Stable Partition

/// Rebuilds the choice sequence with all prefix (lane 0) elements first, followed by all non-prefix elements, preserving relative order within each group.
private func stablePartitionByPrefix(
    _ sequence: ChoiceSequence,
    elements: [SequenceElement],
    laneControlPositions: [UInt64]
) -> ChoiceSequence {
    guard elements.isEmpty == false else { return sequence }

    let headerEnd = elements[0].range.lowerBound
    let lastElement = elements[elements.count - 1]
    let trailerStart = lastElement.range.upperBound + 1

    var prefixSlices: [ArraySlice<ChoiceSequenceValue>] = []
    var concurrentSlices: [ArraySlice<ChoiceSequenceValue>] = []

    for (index, element) in elements.enumerated() {
        let slice = sequence[element.range]
        if laneControlPositions[index] == 0 {
            prefixSlices.append(slice)
        } else {
            concurrentSlices.append(slice)
        }
    }

    var result = ContiguousArray<ChoiceSequenceValue>()
    result.reserveCapacity(sequence.count)

    result.append(contentsOf: sequence[..<headerEnd])
    for slice in prefixSlices { result.append(contentsOf: slice) }
    for slice in concurrentSlices { result.append(contentsOf: slice) }
    if trailerStart < sequence.count {
        result.append(contentsOf: sequence[trailerStart...])
    }

    return ChoiceSequence(result)
}
