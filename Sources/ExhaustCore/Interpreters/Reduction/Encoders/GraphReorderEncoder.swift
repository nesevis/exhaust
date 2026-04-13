//
//  GraphReorderEncoder.swift
//  Exhaust
//

/// Reorders elements within type-homogeneous sibling groups into ascending numeric order.
///
/// Shortlex reduction produces counterexamples like `[0, -1, 1]` because zigzag encoding maps `-1` to shortlex key `1` and `1` to key `2`. This encoder reorders to `[-1, 0, 1]` — the ascending numeric order a user expects — and validates that the property still fails.
///
/// Runs as a final pass after the main graph reduction loop. Receives a pre-filtered ``NumericReorderScope`` from ``ReorderingScopeQuery`` and emits one probe per eligible group, deepest-first. On acceptance, ``refreshScope(graph:sequence:)`` updates the internal sequence so subsequent groups operate on the latest accepted state.
struct GraphReorderEncoder: GraphEncoder {
    let name: EncoderName = .numericReorder

    private var groups: [ReorderableGroup] = []
    private var groupIndex: Int = 0
    private var currentSequence: ChoiceSequence = []

    mutating func start(scope: TransformationScope) {
        guard case let .reorder(.numericReorder(reorderScope)) = scope.transformation.operation else {
            groups = []
            groupIndex = 0
            return
        }
        groups = reorderScope.groups
        groupIndex = 0
        currentSequence = scope.baseSequence
    }

    /// Emits the next group's reordering probe or `nil` when all groups have been attempted.
    ///
    /// Skips groups that are already in natural order. The `lastAccepted` parameter is intentionally ignored: ``refreshScope(graph:sequence:)`` delivers the updated sequence after every accepted probe, keeping ``currentSequence`` in sync without needing to re-examine the acceptance flag here.
    mutating func nextProbe(lastAccepted _: Bool) -> EncoderProbe? {
        while groupIndex < groups.count {
            let group = groups[groupIndex]
            groupIndex += 1
            let ranges = group.ranges

            // Re-extract keys from the current sequence so subsequent groups
            // see the arrangement settled by earlier accepted reorderings.
            let keys = ranges.map {
                ChoiceSequence.siblingComparisonKey(from: currentSequence, range: $0)
            }

            let sortedIndices = keys.indices.sorted { lhs, rhs in
                naturalOrderPrecedes(keys[lhs], keys[rhs])
            }
            guard sortedIndices != Array(keys.indices) else { continue }

            let candidate = rebuildWithPermutation(
                sequence: currentSequence,
                ranges: ranges,
                sortedIndices: sortedIndices
            )

            return EncoderProbe(candidate: candidate, mutation: .sequenceReordered)
        }
        return nil
    }

    mutating func refreshScope(graph _: ChoiceGraph, sequence: ChoiceSequence) {
        currentSequence = sequence
    }
}

// MARK: - Private Helpers

/// Reconstructs a sequence with siblings rearranged according to the given permutation.
private func rebuildWithPermutation(
    sequence: ChoiceSequence,
    ranges: [ClosedRange<Int>],
    sortedIndices: [Int]
) -> ChoiceSequence {
    let slices = ranges.map { Array(sequence[$0]) }
    let spanStart = ranges[0].lowerBound
    let spanEnd = ranges[ranges.count - 1].upperBound

    var rebuilt = ContiguousArray(sequence[..<spanStart])
    var index = 0
    while index < ranges.count {
        if index > 0 {
            let gapStart = ranges[index - 1].upperBound + 1
            let gapEnd = ranges[index].lowerBound
            if gapStart < gapEnd {
                rebuilt.append(contentsOf: sequence[gapStart ..< gapEnd])
            }
        }
        rebuilt.append(contentsOf: slices[sortedIndices[index]])
        index += 1
    }
    if spanEnd + 1 < sequence.count {
        rebuilt.append(contentsOf: sequence[(spanEnd + 1)...])
    }

    return ChoiceSequence(rebuilt)
}

/// Compares two arrays of ``ChoiceValue`` by natural numeric order.
///
/// Uses ``ChoiceValue``'s `Comparable` conformance which compares signed integers by `Int64` value, unsigned by `UInt64`, and floating-point by `Double` — the ordering a human reader expects.
private func naturalOrderPrecedes(
    _ lhs: [ChoiceValue],
    _ rhs: [ChoiceValue]
) -> Bool {
    for (left, right) in zip(lhs, rhs) {
        if left < right { return true }
        if left > right { return false }
    }
    return lhs.count < rhs.count
}
