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
