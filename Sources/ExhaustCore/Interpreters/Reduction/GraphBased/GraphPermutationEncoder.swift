//
//  GraphPermutationEncoder.swift
//  Exhaust
//

// MARK: - Graph Permutation Encoder

/// Applies a fully specified sibling swap to the base sequence.
///
/// Pure structural encoder: the scope specifies exactly which two children to swap. The encoder exchanges their sequence entries at pre-resolved position ranges. One scope = one probe.
struct GraphPermutationEncoder: GraphEncoder {
    let name: EncoderName = .graphSiblingSwap

    private var candidate: ChoiceSequence?
    private var mutation: ProjectedMutation?
    private var emitted = false

    mutating func start(scope: TransformationScope) {
        emitted = false
        candidate = nil
        mutation = nil

        guard case let .permute(.siblingPermutation(permutationScope)) = scope.transformation.operation else {
            return
        }

        guard let group = permutationScope.swappableGroups.first,
              group.count == 2 else {
            return
        }

        let nodeA = group[0]
        let nodeB = group[1]
        let graph = scope.graph
        let sequence = scope.baseSequence

        guard let rangeA = graph.nodes[nodeA].positionRange,
              let rangeB = graph.nodes[nodeB].positionRange else {
            return
        }

        // Ensure rangeA comes before rangeB for correct surgery.
        let (first, second) = rangeA.lowerBound < rangeB.lowerBound
            ? (rangeA, rangeB)
            : (rangeB, rangeA)

        let entriesFirst = Array(sequence[first.lowerBound ... first.upperBound])
        let entriesSecond = Array(sequence[second.lowerBound ... second.upperBound])

        var result = sequence
        // Replace second range first (higher indices) to avoid index shift.
        result.replaceSubrange(second.lowerBound ... second.upperBound, with: entriesFirst)
        result.replaceSubrange(first.lowerBound ... first.upperBound, with: entriesSecond)

        guard result.shortLexPrecedes(sequence) else { return }
        candidate = result
        // Permutation reorders subtrees but does not change the structural
        // skeleton: positions stay the same, only the values inside the
        // swapped ranges move. Layer 7 will implement the in-place sibling
        // swap; until then this falls through to requiresFullRebuild = true.
        mutation = .siblingsSwapped(zipNodeID: permutationScope.zipNodeID, idA: nodeA, idB: nodeB)
    }

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
        guard emitted == false else { return nil }
        emitted = true
        guard let candidate, let mutation else { return nil }
        return EncoderProbe(candidate: candidate, mutation: mutation)
    }
}
