/// Sorts sibling groups into shortlex ascending order.
///
/// For each sibling group, produces a candidate with siblings reordered by their comparison keys. Only groups that are not already sorted produce candidates. Uses slice-based reconstruction to handle variable-sized sibling ranges.
public struct ReorderSiblingsEncoder: BatchEncoder {
    public let name = "reorderSiblings"
    public let phase = ReductionPhase.reordering

    public var grade: ReductionGrade {
        ReductionGrade(approximation: .exact, maxMaterializations: 0)
    }

    public func estimatedCost(sequence: ChoiceSequence, bindIndex: BindSpanIndex?) -> Int? {
        let count = ChoiceSequence.extractSiblingGroups(from: sequence).count
        guard count > 0 else { return nil }
        // Reordering is a cleanup pass — it should run after value minimization
        // has settled values, not before. Cost is set high so cost-based sorting
        // always places it last among eligible value encoders.
        return Int.max - 1
    }

    public func encode(
        sequence: ChoiceSequence,
        targets: TargetSet
    ) -> any Sequence<ChoiceSequence> {
        guard case let .siblingGroups(groups) = targets else { return [] as [ChoiceSequence] }
        return groups.lazy.compactMap { group -> ChoiceSequence? in
            let ranges = group.ranges
            guard ranges.count >= 2 else { return nil }

            let keys = ranges.map { ChoiceSequence.siblingComparisonKey(from: sequence, range: $0) }
            let sortedIndices = keys.indices.sorted { lhs, rhs in
                choiceValuesPrecede(keys[lhs], keys[rhs])
            }
            guard sortedIndices != Array(keys.indices) else { return nil }

            // Extract slices in original order, then reconstruct with permuted order.
            // This handles variable-sized sibling ranges correctly.
            let slices = ranges.map { Array(sequence[$0]) }
            let spanStart = ranges[0].lowerBound
            let spanEnd = ranges[ranges.count - 1].upperBound

            var candidate = ContiguousArray(sequence[..<spanStart])
            var i = 0
            while i < ranges.count {
                // Include gap between previous range and current range.
                if i > 0 {
                    let gapStart = ranges[i - 1].upperBound + 1
                    let gapEnd = ranges[i].lowerBound
                    if gapStart < gapEnd {
                        candidate.append(contentsOf: sequence[gapStart ..< gapEnd])
                    }
                }
                candidate.append(contentsOf: slices[sortedIndices[i]])
                i += 1
            }
            if spanEnd + 1 < sequence.count {
                candidate.append(contentsOf: sequence[(spanEnd + 1)...])
            }

            guard candidate.shortLexPrecedes(sequence) else { return nil }
            return candidate
        }
    }
}

// MARK: - Helpers

/// Lexicographically compares two sequences of ``ChoiceValue`` by shortlex key.
private func choiceValuesPrecede(
    _ lhs: [ChoiceValue],
    _ rhs: [ChoiceValue]
) -> Bool {
    for (a, b) in zip(lhs, rhs) {
        let aKey = a.shortlexKey
        let bKey = b.shortlexKey
        if aKey < bKey { return true }
        if aKey > bKey { return false }
    }
    return lhs.count < rhs.count
}
