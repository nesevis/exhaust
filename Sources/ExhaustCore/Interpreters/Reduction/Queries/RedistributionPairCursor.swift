/// Preserves whole-scope scheduling metadata without retaining the scope's pair cross products.
struct RedistributionPairSummary: Sendable {
    let pairCount: Int
    let maximumSourceDistance: UInt64
}

/// Allows explicit pair lists and generated graph domains to feed the same bounded encoder ranking.
///
/// Copies advance independently and share only immutable descriptors. Acceptance invalidating the prepared graph requires a new cursor.
enum RedistributionPairCursor: Sendable {
    case buffered(BufferedScopeCursor<RedistributionPair>)
    case generated(GeneratedRedistributionPairCursor)
}

extension RedistributionPairCursor: ScopeCursor {
    mutating func next(lastAccepted: Bool) -> RedistributionPair? {
        switch self {
            case var .buffered(cursor):
                let pair = cursor.next(lastAccepted: lastAccepted)
                self = .buffered(cursor)
                return pair
            case var .generated(cursor):
                let pair = cursor.next(lastAccepted: lastAccepted)
                self = .generated(cursor)
                return pair
        }
    }
}
