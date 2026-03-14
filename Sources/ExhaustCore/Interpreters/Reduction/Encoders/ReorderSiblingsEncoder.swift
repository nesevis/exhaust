/// Sorts sibling groups into shortlex ascending order.
///
/// For each sibling group, produces a candidate with siblings reordered by their comparison keys. Only groups that are not already sorted produce candidates.
public struct ReorderSiblingsEncoder: BatchEncoder {
    public let name = "reorderSiblings"
    public let phase = ReductionPhase.reordering

    public var grade: ReductionGrade {
        ReductionGrade(approximation: .exact, maxMaterializations: 0)
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

            var candidate = sequence
            // Build the reordered content by writing sorted siblings into their destination ranges.
            var writeIdx = 0
            while writeIdx < ranges.count {
                let sourceIdx = sortedIndices[writeIdx]
                let destRange = ranges[writeIdx]
                let srcRange = ranges[sourceIdx]
                if srcRange != destRange {
                    let srcSlice = sequence[srcRange]
                    var pos = destRange.lowerBound
                    for value in srcSlice {
                        candidate[pos] = value
                        pos += 1
                    }
                }
                writeIdx += 1
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
