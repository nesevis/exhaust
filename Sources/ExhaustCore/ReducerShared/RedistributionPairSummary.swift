/// Preserves whole-scope scheduling metadata without retaining the scope's pair cross products.
struct RedistributionPairSummary: Sendable {
    let pairCount: Int
    let maximumSourceDistance: UInt64
}
