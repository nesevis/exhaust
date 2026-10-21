/// Captures the domain as well as the address so exhausted work becomes eligible again after a domain change.
///
/// Equality is hand-written for comparing exhausted scopes across graph rebuilds: it ignores `nodeID`, which rebuilds renumber, and `mayReshapeOnAcceptance`, which the path already determines.
struct ReductionLeaf: Equatable {
    let nodeID: Int
    let position: Int
    let path: ChoicePath
    let choice: ChoiceValue
    let range: ClosedRange<UInt64>
    let bindFingerprints: [UInt64]
    /// Mirrors ``LeafEntry/mayReshapeOnAcceptance``: only a bind inner's edit can make the graph's dependent ranges stale, so every other edit is written in place.
    let mayReshapeOnAcceptance: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.position == rhs.position && lhs.path == rhs.path && lhs.choice == rhs.choice
            && lhs.range == rhs.range && lhs.bindFingerprints == rhs.bindFingerprints
    }
}

// MARK: - Numeric Leaf Metadata

extension ReductionLeaf {
    /// Captures bind sites from nearest to farthest so recovery can compare ancestry after replay.
    static func bindFingerprints(above nodeID: Int, graph: ChoiceGraph) -> [UInt64] {
        var fingerprints: [UInt64] = []
        var ancestor = graph.nodes[nodeID].parent
        while let ancestorID = ancestor {
            let node = graph.nodes[ancestorID]
            if case let .bind(metadata) = node.kind {
                fingerprints.append(metadata.fingerprint)
            }
            ancestor = node.parent
        }
        return fingerprints
    }

    /// Boolean generators use UInt8 in 0...1; exclude that domain, including numeric generators with the same representation.
    static func supportsNumericSearch(_ metadata: ChooseBitsMetadata) -> Bool {
        guard metadata.typeTag != .uint8 || metadata.validRange != 0 ... 1 else {
            return false
        }
        switch metadata.typeTag {
            case .int, .int8, .int16, .int32, .int64, .uint, .uint8, .uint16, .uint32, .uint64:
                return true
            case .float, .float16, .double:
                return metadata.value.decodedDoubleValue.isFinite
            case .date, .bits, .character, .depthControl, .laneControl:
                return false
        }
    }
}
