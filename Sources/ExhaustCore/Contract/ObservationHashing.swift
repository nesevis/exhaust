/// Per-observation fingerprints and prefix fingerprint for linearizability cache keying.
package struct ObservationHashResult {
    package let observationHashes: [[UInt64]]
    package let prefixFingerprint: UInt64

    package init(observationHashes: [[UInt64]], prefixFingerprint: UInt64) {
        self.observationHashes = observationHashes
        self.prefixFingerprint = prefixFingerprint
    }
}

/// Computes per-observation fingerprints from the probe's own ChoiceTree, hashing each command's subtree directly rather than flattening to a ChoiceSequence.
///
/// Contracts don't materialize picks, so each element subtree in the tree's `.sequence` node is a stable structural identity for the command that was generated from it. The prefix fingerprint is an XOR of prefix commands' subtree hashes, so the linearizability cache distinguishes probes that differ only in their prefix. Returns `nil` if any response has a non-hashable `.returned(Any)` outcome or the tree has no `.sequence` node.
package func computeObservationHashesFromTree<Command>(
    probeTree: ChoiceTree,
    taggedCommands: [(ScheduleMarker, Command)],
    laneResponses: [[ObservedResponse<Command>]]
) -> ObservationHashResult? {
    guard let subtrees = ChoiceTree.findSequenceElements(in: probeTree) else { return nil }

    var prefixFingerprint: UInt64 = 0
    var result = laneResponses.map { lane in
        var hashes: [UInt64] = []
        hashes.reserveCapacity(lane.count)
        return hashes
    }
    var laneCursors = Array(repeating: 0, count: laneResponses.count)

    for index in 0 ..< taggedCommands.count {
        let marker = taggedCommands[index].0
        let subtreeHash = subtrees[index].hashValue.bitPattern64

        if marker.isPrefix {
            prefixFingerprint ^= ZobristHash.mix(subtreeHash, at: index)
            continue
        }

        guard let laneIndex = laneResponses.firstIndex(where: { $0.first?.lane == marker.rawValue }) else { continue }
        let cursor = laneCursors[laneIndex]
        guard cursor < laneResponses[laneIndex].count else { return nil }
        let response = laneResponses[laneIndex][cursor]
        let responseHash: UInt64
        switch response.outcome {
            case let .returned(value):
                guard let hashable = value as? AnyHashable else { return nil }
                responseHash = ZobristHash.mix(hashable.hashValue.bitPattern64, at: 0)
            case .returnedVoid:
                responseHash = 0xA
            case .skipped:
                responseHash = 0xB
        }
        result[laneIndex].append(ZobristHash.mix(subtreeHash, at: 0) ^ responseHash)
        laneCursors[laneIndex] = cursor + 1
    }

    for index in 0 ..< laneResponses.count {
        guard laneCursors[index] == laneResponses[index].count else { return nil }
    }
    return ObservationHashResult(observationHashes: result, prefixFingerprint: prefixFingerprint)
}
