//
//  HumanReadableOrderingPass.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

/// Reorders elements within type-homogeneous sibling groups into natural numeric order.
///
/// Shortlex reduction produces counterexamples like `[0, -1, 1]` because zigzag encoding maps `-1` to shortlex key `1` and `1` to key `2`. This encoder reorders to `[-1, 0, 1]` — the natural numeric ordering a human reader expects — and validates that the property still fails.
///
/// This is a natural endotransformation of Cand in the sense of Sepúlveda-Jiménez (Definition 5.3) — a post-processing map that is reduction-invariant.
public struct HumanReadableOrderingPass: ReductionPass {
    public let name: EncoderName = .humanOrderReorder

    /// Reorders sibling groups into natural numeric order and validates the property still fails.
    ///
    /// Processes each eligible group deepest-first, validating each reordering independently. Returns the improved result with all successful reorderings applied, or `nil` if no reorderings were accepted.
    ///
    /// - Parameters:
    ///   - gen: The generator to materialize through.
    ///   - sequence: The current choice sequence.
    ///   - tree: The current choice tree.
    ///   - property: The property predicate.
    /// - Returns: The reordered result with materialization count, or `nil` if no groups were reordered.
    public func encode<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        property: (Output) -> Bool
    ) -> (result: ReductionPassResult<Output>, materializations: Int)? {
        let groups = ChoiceSequence.extractSiblingGroups(from: sequence)
        guard groups.isEmpty == false else { return nil }

        // Build bind-inner ranges to exclude from reordering. Reordering siblings
        // that contain bind-inner values corrupts the structural semantics — the
        // bind-inner constrains the downstream generator, so swapping it with a
        // sibling transposes the constraint and the bound content.
        let bindIndex = BindSpanIndex(from: sequence)
        let bindInnerRanges = bindIndex.regions.map(\.innerRange)

        // Filter to type-homogeneous groups that do not contain bind-inner positions.
        let homogeneousGroups = groups.filter { group in
            guard group.ranges.count >= 2 else { return false }

            for siblingRange in group.ranges {
                for innerRange in bindInnerRanges {
                    if siblingRange.overlaps(innerRange) { return false }
                }
            }

            let keys = group.ranges.map {
                ChoiceSequence.siblingComparisonKey(from: sequence, range: $0)
            }
            let firstLength = keys[0].count
            guard firstLength > 0 else { return false }
            for key in keys {
                guard key.count == firstLength else { return false }
            }
            for position in 0 ..< firstLength {
                let firstTag = keys[0][position].tag
                for key in keys.dropFirst() {
                    guard key[position].tag == firstTag else { return false }
                }
            }
            return true
        }

        guard homogeneousGroups.isEmpty == false else { return nil }

        // Sort deepest-first so inner groups settle before outer groups compare them.
        // Within the same depth, rightmost-first to avoid index invalidation.
        let sortedGroups = homogeneousGroups.sorted { lhs, rhs in
            if lhs.depth != rhs.depth {
                return lhs.depth > rhs.depth
            }
            return lhs.ranges[0].lowerBound > rhs.ranges[0].lowerBound
        }

        var bestSequence = sequence
        var bestTree = tree
        var bestOutput: Output?
        var materializations = 0

        for group in sortedGroups {
            let ranges = group.ranges
            // Re-extract keys from the current (possibly already reordered) best
            // sequence.
            let keys = ranges.map {
                ChoiceSequence.siblingComparisonKey(from: bestSequence, range: $0)
            }

            let sortedIndices = keys.indices.sorted { lhs, rhs in
                naturalOrderPrecedes(keys[lhs], keys[rhs])
            }
            guard sortedIndices != Array(keys.indices) else { continue }

            let candidate = rebuildWithPermutation(
                sequence: bestSequence,
                ranges: ranges,
                sortedIndices: sortedIndices
            )

            materializations += 1
            if let result = Self.decode(
                candidate: candidate,
                gen: gen,
                fallbackTree: bestTree,
                property: property
            ) {
                bestSequence = result.sequence
                bestTree = result.tree
                bestOutput = result.output
            }
        }

        guard let output = bestOutput else { return nil }
        return (
            result: ReductionPassResult(
                sequence: bestSequence,
                tree: bestTree,
                output: output
            ),
            materializations: materializations
        )
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
