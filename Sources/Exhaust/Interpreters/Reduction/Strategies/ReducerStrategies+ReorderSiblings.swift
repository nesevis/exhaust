//
//  ReducerStrategies+ReorderSiblings.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

extension ReducerStrategies {
    /// Pass 6: Reorder sibling elements within containers to produce normalized output.
    /// For each sibling group, tries sorting all siblings by their comparison keys.
    /// Falls back to adjacent swaps (bubble-sort style) if the full sort is rejected.
    ///
    /// - Complexity: O(*g* · *r*² · *M*), where *g* is the number of sibling groups, *r* is the
    ///   maximum number of siblings in a group, and *M* is the cost of a single oracle call. Each
    ///   group first attempts a full sort (1 oracle call), then falls back to bubble-sort with up to
    ///   O(*r*²) swap attempts. Successful swaps trigger group re-extraction in O(*s*).
    static func reorderSiblings<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        siblingGroups: [SiblingGroup],
        rejectCache: inout ReducerCache,
    ) throws -> (ChoiceSequence, Output)? {
        var current = sequence
        var progress = false
        var latestOutput: Output?
        var liveGroups = siblingGroups

        var groupIndex = 0
        while groupIndex < liveGroups.count {
            let group = liveGroups[groupIndex]
            let ranges = group.ranges
            guard ranges.count >= 2 else {
                groupIndex += 1
                continue
            }

            // Compute comparison keys for each sibling
            let keys = ranges.map { ChoiceSequence.siblingComparisonKey(from: current, range: $0) }

            // Check if already sorted
            let sortedIndices = keys.indices.sorted { lhs, rhs in
                lexicographicallyPrecedes(keys[lhs], keys[rhs])
            }

            if sortedIndices == Array(keys.indices) {
                groupIndex += 1
                continue
            }

            // Build a candidate with siblings in sorted order
            if let (newSeq, output) = try applySiblingPermutation(
                gen, tree: tree, property: property,
                sequence: current, ranges: ranges, permutation: sortedIndices, rejectCache: &rejectCache,
            ) {
                current = newSeq
                latestOutput = output
                progress = true
                // Re-extract all groups with fresh ranges
                liveGroups = ChoiceSequence.extractSiblingGroups(from: current)
                groupIndex = 0
                continue
            }

            // Full sort failed — bubble sort with live range re-extraction
            var improved = true
            while improved {
                improved = false
                let freshRanges = ChoiceSequence.extractSiblingGroups(from: current)
                    .first(where: { $0.depth == group.depth && $0.ranges.count == ranges.count })?.ranges
                guard let liveRanges = freshRanges else { break }

                for j in 0 ..< (liveRanges.count - 1) {
                    let keyA = ChoiceSequence.siblingComparisonKey(from: current, range: liveRanges[j])
                    let keyB = ChoiceSequence.siblingComparisonKey(from: current, range: liveRanges[j + 1])

                    guard !lexicographicallyPrecedes(keyA, keyB), keyA != keyB else { continue }

                    // Swap j and j+1
                    var swapPerm = Array(0 ..< liveRanges.count)
                    swapPerm.swapAt(j, j + 1)

                    if let (newSeq, output) = try applySiblingPermutation(
                        gen, tree: tree, property: property,
                        sequence: current, ranges: liveRanges, permutation: swapPerm, rejectCache: &rejectCache,
                    ) {
                        current = newSeq
                        latestOutput = output
                        progress = true
                        improved = true
                        break // Restart bubble pass with fresh ranges
                    }
                }
            }

            // Re-extract for subsequent groups after finishing this one
            liveGroups = ChoiceSequence.extractSiblingGroups(from: current)
            groupIndex += 1
        }

        if progress, let output = latestOutput {
            return (current, output)
        }
        return nil
    }

    /// Applies a permutation to sibling ranges in a sequence, checks shortlex precedence,
    /// materializes, and tests the property.
    ///
    /// - Complexity: O(*s* + *M*), where *s* is the sequence length and *M* is the cost of a
    ///   single oracle call. Reconstructs the permuted sequence in O(*s*), then makes one oracle call.
    static func applySiblingPermutation<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        ranges: [ClosedRange<Int>],
        permutation: [Int],
        rejectCache: inout ReducerCache,
    ) throws -> (ChoiceSequence, Output)? {
        // Extract the slices in original order
        let slices = ranges.map { Array(sequence[$0]) }

        // Build candidate by reconstructing: prefix + permuted siblings interleaved + suffix
        // Since siblings are contiguous within their parent container, we can replace the
        // entire span from first range start to last range end.
        let spanStart = ranges.first!.lowerBound
        let spanEnd = ranges.last!.upperBound

        // Prepopulate with outer spans
        var candidate = Array(sequence[..<spanStart])
        for i in ranges.indices {
            // If there's a gap between previous range end and current range start, include it
            if i > 0 {
                let gapStart = ranges[i - 1].upperBound + 1
                let gapEnd = ranges[i].lowerBound
                if gapStart < gapEnd {
                    candidate.append(contentsOf: sequence[gapStart ..< gapEnd])
                }
            }
            candidate.append(contentsOf: slices[permutation[i]])
        }
        if spanEnd + 1 < sequence.count {
            candidate.append(contentsOf: sequence[(spanEnd + 1)...])
        }

        // We are allowing this change to ignore shortlex in the hopes that it unlocks
        // a partial reduction that unlocks further ones. See `LargeUnionList` and `Difference`
//        guard candidate.shortLexPrecedes(sequence) else { return nil }
        guard rejectCache.contains(candidate) == false else { return nil }
        guard let output = try? Interpreters.materialize(gen, with: tree, using: candidate) else {
            rejectCache.insert(candidate)
            return nil
        }
        guard property(output) == false else {
            rejectCache.insert(candidate)
            return nil
        }

        return (candidate, output)
    }

    /// Lexicographic comparison of two `[ChoiceValue]` arrays.
    ///
    /// - Complexity: O(min(*a*, *b*)), where *a* and *b* are the lengths of the two arrays.
    static func lexicographicallyPrecedes(_ lhs: [ChoiceValue], _ rhs: [ChoiceValue]) -> Bool {
        for (a, b) in zip(lhs, rhs) {
            if a.tag != b.tag {
                return choiceTagRank(a.tag) < choiceTagRank(b.tag)
            }
            if a < b { return true }
            if b < a { return false }
        }
        return lhs.count < rhs.count
    }

    private static func choiceTagRank(_ tag: TypeTag) -> Int {
        switch tag {
        case .int, .int8, .int16, .int32, .int64:
            0
        case .uint, .uint8, .uint16, .uint32, .uint64:
            1
        case .float, .double:
            2
        case .character:
            3
        }
    }
}
