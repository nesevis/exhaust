/// One-shot post-processing pass that reorders elements within type-homogeneous sibling groups
/// into natural numeric order. Runs after the V-cycle stalls.
///
/// Shortlex reduction produces counterexamples like `[0, -1, 1]` because zigzag encoding maps
/// `-1` to shortlex key `1` and `1` to key `2`. This pass reorders to `[-1, 0, 1]` — the natural
/// numeric ordering a human reader expects — and validates that the property still fails.
extension ReductionScheduler {
    static func humanOrderPostProcess<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        property: (Output) -> Bool
    ) -> (sequence: ChoiceSequence, tree: ChoiceTree, output: Output)? {
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

            // Exclude groups where any sibling range overlaps a bind-inner range.
            for siblingRange in group.ranges {
                for innerRange in bindInnerRanges {
                    if siblingRange.overlaps(innerRange) { return false }
                }
            }

            let keys = group.ranges.map { ChoiceSequence.siblingComparisonKey(from: sequence, range: $0) }
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

        for group in sortedGroups {
            let ranges = group.ranges
            // Re-extract keys from the current (possibly already reordered) best sequence.
            let keys = ranges.map { ChoiceSequence.siblingComparisonKey(from: bestSequence, range: $0) }

            let sortedIndices = keys.indices.sorted { lhs, rhs in
                naturalOrderPrecedes(keys[lhs], keys[rhs])
            }
            guard sortedIndices != Array(keys.indices) else { continue }

            // Slice-reconstruction pattern from ReorderSiblingsEncoder.
            let slices = ranges.map { Array(bestSequence[$0]) }
            let spanStart = ranges[0].lowerBound
            let spanEnd = ranges[ranges.count - 1].upperBound

            var rebuilt = ContiguousArray(bestSequence[..<spanStart])
            var index = 0
            while index < ranges.count {
                if index > 0 {
                    let gapStart = ranges[index - 1].upperBound + 1
                    let gapEnd = ranges[index].lowerBound
                    if gapStart < gapEnd {
                        rebuilt.append(contentsOf: bestSequence[gapStart ..< gapEnd])
                    }
                }
                rebuilt.append(contentsOf: slices[sortedIndices[index]])
                index += 1
            }
            if spanEnd + 1 < bestSequence.count {
                rebuilt.append(contentsOf: bestSequence[(spanEnd + 1)...])
            }

            let candidate = ChoiceSequence(rebuilt)

            // Validate each group's reordering independently. A reordering that breaks the
            // property (for example, sorting characters within a string to make two anagram
            // strings identical) is rejected without poisoning other groups.
            let seed = ZobristHash.hash(of: candidate)
            switch ReductionMaterializer.materialize(
                gen,
                prefix: candidate,
                mode: .guided(seed: seed, fallbackTree: bestTree)
            ) {
            case let .success(output, freshTree, _):
                guard property(output) == false else { continue }
                bestSequence = ChoiceSequence(freshTree)
                bestTree = freshTree
                bestOutput = output
            case .rejected, .failed:
                continue
            }
        }

        guard let output = bestOutput else { return nil }
        return (sequence: bestSequence, tree: bestTree, output: output)
    }
}

// MARK: - Helpers

/// Lexicographically compares two sequences of ``ChoiceValue`` by natural numeric order.
///
/// Uses `ChoiceValue`'s `Comparable` conformance which compares signed integers by `Int64` value,
/// unsigned by `UInt64`, and floating-point by `Double` — the ordering a human reader expects.
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
