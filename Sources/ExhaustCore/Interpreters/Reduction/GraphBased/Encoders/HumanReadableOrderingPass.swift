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

        // Filter to tag-compatible sibling groups outside bind-inner regions.
        // Variable-length siblings from the same generator (for example a tuple of arrays with the same length range) are reorderable as long as their value entries share a tag — the materializer rejects any candidate whose new arrangement violates a per-position length constraint.
        let compatibleGroups = groups.filter { group in
            guard group.ranges.count >= 2 else { return false }

            for siblingRange in group.ranges {
                for innerRange in bindInnerRanges {
                    if siblingRange.overlaps(innerRange) { return false }
                }
            }

            let keys = group.ranges.map {
                ChoiceSequence.siblingComparisonKey(from: sequence, range: $0)
            }

            // For different-size siblings, only attempt permutation when every
            // sibling's key has at most one value. Keys with more than one value
            // encode picks or nested zip structure — swapping different-size chunks
            // of those causes the guided decoder to overread into the wrong region
            // and fill the remainder from the fallback tree, producing semantically
            // larger output. Single-scalar keys (for example an array of integers)
            // are safe because the sequence-open/close delimiters make each sibling
            // self-delimiting regardless of element count.
            let firstSize = group.ranges[0].count
            if group.ranges.allSatisfy({ $0.count == firstSize }) == false {
                guard keys.allSatisfy({ $0.count <= 1 }) else { return false }
            }

            // All value entries across all keys must share a single tag. Empty keys trivially pass and pure-empty groups have nothing to reorder.
            var seenTag: TypeTag?
            for key in keys {
                for value in key {
                    if let existing = seenTag {
                        guard value.tag == existing else { return false }
                    } else {
                        seenTag = value.tag
                    }
                }
            }
            return seenTag != nil
        }

        guard compatibleGroups.isEmpty == false else { return nil }

        // Sort deepest-first so inner groups settle before outer groups compare them.
        // Within the same depth, rightmost-first to avoid index invalidation.
        let sortedGroups = compatibleGroups.sorted { lhs, rhs in
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
