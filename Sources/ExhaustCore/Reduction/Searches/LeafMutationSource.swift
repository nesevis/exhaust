//
//  LeafMutationSource.swift
//  Exhaust
//

// MARK: - Leaf Mutation Source

/// A leaf a value search can change, with what a `.leafValues` mutation needs to report the change.
protocol LeafMutationSource {
    var nodeID: Int { get }
    var sequenceIndex: Int { get }
    var mayReshape: Bool { get }
}

extension Sequence where Element: LeafMutationSource {
    /// Builds a `.leafValues` mutation by diffing `candidate` against `baseline` at each leaf's sequence index.
    func leafValuesMutation(candidate: ChoiceSequence, baseline: ChoiceSequence) -> ProjectedMutation {
        var changes: [LeafChange] = []
        for leaf in self {
            guard leaf.sequenceIndex < candidate.count,
                  leaf.sequenceIndex < baseline.count
            else {
                continue
            }
            guard let candidateChoice = candidate[leaf.sequenceIndex].value?.choice,
                  let baselineChoice = baseline[leaf.sequenceIndex].value?.choice
            else {
                continue
            }
            guard candidateChoice != baselineChoice else {
                continue
            }
            changes.append(LeafChange(
                leafNodeID: leaf.nodeID,
                newValue: candidateChoice,
                mayReshape: leaf.mayReshape
            ))
        }
        return .leafValues(changes)
    }
}
