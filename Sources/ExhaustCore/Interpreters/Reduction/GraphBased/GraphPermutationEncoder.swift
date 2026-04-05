//
//  GraphPermutationEncoder.swift
//  Exhaust
//

// MARK: - Graph Permutation Encoder

/// Reorders same-shaped siblings within zip nodes to achieve shortlex-minimal ordering.
///
/// For each swappable group in the scope, tries pairwise content swaps. Uses the tree for child manipulation and flattens to produce candidate sequences. A swap is accepted if the resulting sequence is shortlex-smaller.
///
/// Permutation has zero structural and value yield — it is accepted purely on shortlex improvement.
struct GraphPermutationEncoder: GraphEncoder {
    let name: EncoderName = .graphSiblingSwap

    // MARK: - State

    private var candidates: [ChoiceSequence] = []
    private var candidateIndex = 0

    // MARK: - GraphEncoder

    mutating func start(scope: TransformationScope) {
        candidateIndex = 0
        candidates = []

        guard case let .permutation(.siblingPermutation(permutationScope)) = scope.transformation.operation else {
            return
        }

        let sequence = scope.baseSequence
        let graph = scope.graph

        for group in permutationScope.swappableGroups {
            guard group.count >= 2 else { continue }
            for indexA in 0 ..< group.count {
                for indexB in (indexA + 1) ..< group.count {
                    let nodeA = group[indexA]
                    let nodeB = group[indexB]
                    guard let rangeA = graph.nodes[nodeA].positionRange,
                          let rangeB = graph.nodes[nodeB].positionRange else {
                        continue
                    }
                    // Swap sequence entries at the two position ranges.
                    if let candidate = buildSwapCandidate(
                        rangeA: rangeA,
                        rangeB: rangeB,
                        sequence: sequence
                    ) {
                        candidates.append(candidate)
                    }
                }
            }
        }
    }

    mutating func nextProbe(lastAccepted _: Bool) -> ChoiceSequence? {
        guard candidateIndex < candidates.count else { return nil }
        let candidate = candidates[candidateIndex]
        candidateIndex += 1
        return candidate
    }

    // MARK: - Candidate Construction

    /// Builds a swap candidate by exchanging sequence entries at two position ranges.
    ///
    /// Both ranges must be in the same sequence (both children of the same zip). The entries at range A are moved to where range B was and vice versa.
    private func buildSwapCandidate(
        rangeA: ClosedRange<Int>,
        rangeB: ClosedRange<Int>,
        sequence: ChoiceSequence
    ) -> ChoiceSequence? {
        // Ensure rangeA comes before rangeB.
        let (first, second) = rangeA.lowerBound < rangeB.lowerBound
            ? (rangeA, rangeB)
            : (rangeB, rangeA)

        let entriesFirst = Array(sequence[first.lowerBound ... first.upperBound])
        let entriesSecond = Array(sequence[second.lowerBound ... second.upperBound])

        var candidate = sequence
        // Replace second range first (higher indices), then first range,
        // so index arithmetic is not affected.
        candidate.replaceSubrange(second.lowerBound ... second.upperBound, with: entriesFirst)
        candidate.replaceSubrange(first.lowerBound ... first.upperBound, with: entriesSecond)

        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }
}
