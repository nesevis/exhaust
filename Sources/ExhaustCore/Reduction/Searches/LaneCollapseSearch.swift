//
//  LaneCollapseSearch.swift
//  Exhaust
//

// MARK: - Lane Collapse Search

/// Drives ``TypeTag/laneControl`` values to zero and canonicalizes element order so all prefix commands are contiguous at the front.
///
/// Each candidate is a binary decision: set one lane marker to zero, then stable-partition the sequence elements so all prefix (lane 0) elements precede all concurrent elements, preserving relative order within each group. The candidate presented to the property always has the canonical `[0, 0, 0, X, Y, X]` layout.
///
/// Leaves are processed front-to-back so the prefix grows from the beginning of the command sequence. A reordered sequence needs a full graph rebuild, so an acceptance always ends the pass and the search only ever works from its base sequence.
struct LaneCollapseSearch: ReductionSearch {
    /// Positions of the lane markers to zero, in sequence order. Markers outside every sequence element are left alone.
    private let leafPositions: [Int]
    private var leafIndex: Int = 0
    private let baseSequence: ChoiceSequence
    private let elements: [SequenceElement]

    init(leaves leafEntries: [LeafEntry], graph: ChoiceGraph, baseSequence: ChoiceSequence) {
        self.baseSequence = baseSequence
        let elements = Self.collectSequenceElements(graph: graph)
        self.elements = elements
        leafPositions = leafEntries.compactMap { entry -> Int? in
            guard let leafPosition = graph.nodes[entry.nodeID].positionRange?.lowerBound,
                  elements.contains(where: { $0.range.contains(leafPosition) })
            else {
                return nil
            }
            return leafPosition
        }
        .sorted()
    }

    mutating func next(_: SearchFeedback, into buffer: inout ChoiceSequence) -> ReductionCandidate? {
        while leafIndex < leafPositions.count {
            let leafPosition = leafPositions[leafIndex]
            leafIndex += 1

            guard leafPosition < baseSequence.count else {
                continue
            }
            guard case let .value(entry) = baseSequence[leafPosition] else {
                continue
            }
            guard entry.choice.bitPattern64 != 0 else {
                continue
            }

            buffer = baseSequence

            let zeroValue = ChoiceValue(UInt64(0), tag: entry.choice.tag)
            buffer[leafPosition] = .value(ChoiceSequenceValue.Value(
                choice: zeroValue,
                validRange: entry.validRange,
                isRangeExplicit: entry.isRangeExplicit
            ))

            buffer = Self.stablePartitionByPrefix(buffer, elements: elements, laneControlValues: Self.collectLaneControlValues(in: buffer, elements: elements))

            return .written(mutation: .sequenceReordered, admission: .standard)
        }
        return nil
    }

    // MARK: - Types

    private struct SequenceElement {
        let range: ClosedRange<Int>
    }

    // MARK: - Element Collection

    /// Finds the outermost `.sequence` node in the graph and collects the position range of each child element.
    private static func collectSequenceElements(graph: ChoiceGraph) -> [SequenceElement] {
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            if case let .sequence(metadata) = node.kind {
                return metadata.childPositionRanges.map { SequenceElement(range: $0) }
            }
        }
        return []
    }

    // MARK: - Lane Control Detection

    /// Returns the lane marker value of each element, read from the `.laneControl`-tagged entry in its range, or `UInt64.max` when the element has none, which places it among the concurrent elements.
    private static func collectLaneControlValues(
        in sequence: ChoiceSequence,
        elements: [SequenceElement]
    ) -> [UInt64] {
        elements.map { element in
            for position in element.range {
                guard position < sequence.count else {
                    break
                }
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
    private static func stablePartitionByPrefix(
        _ sequence: ChoiceSequence,
        elements: [SequenceElement],
        laneControlValues: [UInt64]
    ) -> ChoiceSequence {
        guard elements.isEmpty == false else {
            return sequence
        }

        let headerEnd = elements[0].range.lowerBound
        let lastElement = elements[elements.count - 1]
        let trailerStart = lastElement.range.upperBound + 1

        var prefixSlices: [ArraySlice<ChoiceSequenceValue>] = []
        var concurrentSlices: [ArraySlice<ChoiceSequenceValue>] = []

        for (index, element) in elements.enumerated() {
            let slice = sequence[element.range]
            if laneControlValues[index] == 0 {
                prefixSlices.append(slice)
            } else {
                concurrentSlices.append(slice)
            }
        }

        var result = ContiguousArray<ChoiceSequenceValue>()
        result.reserveCapacity(sequence.count)

        result.append(contentsOf: sequence[..<headerEnd])
        for slice in prefixSlices {
            result.append(contentsOf: slice)
        }
        for slice in concurrentSlices {
            result.append(contentsOf: slice)
        }
        if trailerStart < sequence.count {
            result.append(contentsOf: sequence[trailerStart...])
        }

        return ChoiceSequence(result)
    }
}
