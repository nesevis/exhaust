//
//  ValueEncoderState.swift
//  Exhaust
//

// MARK: - Value Encoder State

/// Shared baseline and leaf-lookup infrastructure for value encoders (redistribution, lockstep).
///
/// Owns the baseline ``sequence`` (updated on acceptance), the ``leafLookup`` (maps sequence index to graph node ID and reshape marker), and the ``buildLeafValuesMutation(candidate:)`` method that diffs a candidate against the baseline to produce a ``ProjectedMutation/leafValues(_:)`` report.
struct ValueEncoderState {
    /// The current baseline sequence. Updated when a probe is accepted.
    var sequence: ChoiceSequence = .init()

    /// Maps the sequence index of every leaf the current scope can touch to its graph node ID and bind-inner reshape marker. Built once at scope start and read by ``buildLeafValuesMutation(candidate:)`` to construct mutation reports without diffing the entire sequence.
    var leafLookup: [Int: (nodeID: Int, mayReshape: Bool)] = [:]

    /// Resets the state for a new scope.
    mutating func reset(sequence: ChoiceSequence) {
        self.sequence = sequence
        leafLookup.removeAll(keepingCapacity: true)
    }

    /// Registers a leaf node in the lookup by its sequence position.
    mutating func registerLeaf(nodeID: Int, mayReshape: Bool, graph: ChoiceGraph) {
        if let range = graph.nodes[nodeID].positionRange {
            leafLookup[range.lowerBound] = (nodeID, mayReshape)
        }
    }

    /// Diffs a candidate against the baseline and returns a `.leafValues` mutation listing every leaf whose value changed.
    func buildLeafValuesMutation(candidate: ChoiceSequence) -> ProjectedMutation {
        var changes: [LeafChange] = []
        for (sequenceIndex, info) in leafLookup {
            guard sequenceIndex < candidate.count, sequenceIndex < sequence.count else { continue }
            guard let candidateChoice = candidate[sequenceIndex].value?.choice,
                  let baselineChoice = sequence[sequenceIndex].value?.choice
            else { continue }
            guard candidateChoice != baselineChoice else { continue }
            changes.append(LeafChange(
                leafNodeID: info.nodeID,
                newValue: candidateChoice,
                mayReshape: info.mayReshape
            ))
        }
        return .leafValues(changes)
    }
}
