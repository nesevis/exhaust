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

            // ``ReorderingScopeQuery`` buckets siblings by outer-node ``ChoiceGraphNodeKind`` category. For container kinds (bind, zip, sequence, pick) the inner structure may diverge across siblings — for example, two recursive bind siblings where one took a base-case branch and the other took a non-base branch will flatten to different ``ChoiceValue`` type profiles. ``naturalOrderPrecedes`` traps on mismatched tag categories (unsigned vs signed vs floating), so skip any group whose keys are not pairwise type-compatible rather than attempting to sort them.
            guard keysAreTypeCompatible(keys) else { continue }

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

/// Returns `true` when every pair of keys has matching length and matching ``TypeTag`` at each position.
///
/// Two reasons to enforce exact tag equality rather than just category equality (unsigned/signed/floating): (1) ``ChoiceValue``'s `<` operator traps on mismatched categories, so the guard avoids a fatalError; (2) swapping values across different bit widths of the same category (for example, `Int16` and `Int32` slots) would reassign content to a slot whose bit-pattern range does not fit it, producing an invalid reordered candidate the materializer would reject or, worse, misinterpret.
private func keysAreTypeCompatible(_ keys: [[ChoiceValue]]) -> Bool {
    guard let first = keys.first else { return true }
    for other in keys.dropFirst() {
        guard first.count == other.count else { return false }
        for (left, right) in zip(first, other) where left.tag != right.tag {
            return false
        }
    }
    return true
}
