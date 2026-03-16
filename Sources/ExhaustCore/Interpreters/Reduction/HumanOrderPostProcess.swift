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
        useReductionMaterializer: Bool,
        property: (Output) -> Bool
    ) -> (sequence: ChoiceSequence, tree: ChoiceTree, output: Output)? {
        let groups = ChoiceSequence.extractSiblingGroups(from: sequence)
        guard groups.isEmpty == false else { return nil }

        // Filter to type-homogeneous groups: all siblings must have the same number of
        // ChoiceValues and the same TypeTag at each position.
        let homogeneousGroups = groups.filter { group in
            guard group.ranges.count >= 2 else { return false }
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

        var candidate = sequence
        var changed = false

        for group in sortedGroups {
            let ranges = group.ranges
            // Re-extract keys from the current (possibly already reordered) candidate.
            let keys = ranges.map { ChoiceSequence.siblingComparisonKey(from: candidate, range: $0) }

            let sortedIndices = keys.indices.sorted { lhs, rhs in
                naturalOrderPrecedes(keys[lhs], keys[rhs])
            }
            guard sortedIndices != Array(keys.indices) else { continue }

            // Slice-reconstruction pattern from ReorderSiblingsEncoder.
            let slices = ranges.map { Array(candidate[$0]) }
            let spanStart = ranges[0].lowerBound
            let spanEnd = ranges[ranges.count - 1].upperBound

            var rebuilt = ContiguousArray(candidate[..<spanStart])
            var index = 0
            while index < ranges.count {
                if index > 0 {
                    let gapStart = ranges[index - 1].upperBound + 1
                    let gapEnd = ranges[index].lowerBound
                    if gapStart < gapEnd {
                        rebuilt.append(contentsOf: candidate[gapStart ..< gapEnd])
                    }
                }
                rebuilt.append(contentsOf: slices[sortedIndices[index]])
                index += 1
            }
            if spanEnd + 1 < candidate.count {
                rebuilt.append(contentsOf: candidate[(spanEnd + 1)...])
            }

            candidate = ChoiceSequence(rebuilt)
            changed = true
        }

        guard changed else { return nil }

        // Materialize and validate. No shortLexPrecedes guard — human order intentionally may not
        // be shortlex-smaller.
        let seed = ZobristHash.hash(of: candidate)
        if useReductionMaterializer {
            switch ReductionMaterializer.materialize(
                gen,
                prefix: candidate,
                mode: .guided(seed: seed, fallbackTree: tree)
            ) {
            case let .success(output, freshTree):
                guard property(output) == false else { return nil }
                let freshSequence = ChoiceSequence(freshTree)
                return (sequence: freshSequence, tree: freshTree, output: output)
            case .rejected, .failed:
                return nil
            }
        } else {
            switch GuidedMaterializer.materialize(gen, prefix: candidate, seed: seed, fallbackTree: tree) {
            case let .success(output, materializedSequence, materializedTree):
                guard property(output) == false else { return nil }
                return (sequence: materializedSequence, tree: materializedTree, output: output)
            case .filterEncountered, .failed:
                return nil
            }
        }
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
