//
//  GraphStructuralEncoder+Swap.swift
//  Exhaust
//

extension GraphStructuralEncoder {
    /// Builds a sibling swap probe from a permutation scope.
    func buildSwapProbe(
        scope: PermutationScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> EncoderProbe? {
        guard case let .siblingPermutation(permutationScope) = scope else { return nil }
        guard let group = permutationScope.swappableGroups.first,
              group.count == 2
        else {
            return nil
        }

        let nodeA = group[0]
        let nodeB = group[1]

        guard let rangeA = graph.nodes[nodeA].positionRange,
              let rangeB = graph.nodes[nodeB].positionRange
        else {
            return nil
        }

        let (first, second) = rangeA.lowerBound < rangeB.lowerBound
            ? (rangeA, rangeB)
            : (rangeB, rangeA)

        let entriesFirst = Array(sequence[first.lowerBound ... first.upperBound])
        let entriesSecond = Array(sequence[second.lowerBound ... second.upperBound])

        var result = sequence
        result.replaceSubrange(second.lowerBound ... second.upperBound, with: entriesFirst)
        result.replaceSubrange(first.lowerBound ... first.upperBound, with: entriesSecond)

        guard result.shortLexPrecedes(sequence) else { return nil }
        return EncoderProbe(
            candidate: result,
            mutation: .siblingsSwapped(zipNodeID: permutationScope.zipNodeID, idA: nodeA, idB: nodeB)
        )
    }
}
