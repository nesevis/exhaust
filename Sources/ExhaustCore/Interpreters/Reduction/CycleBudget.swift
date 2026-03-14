/// Per-cycle resource allocation across V-cycle legs.
///
/// Each leg receives a fraction of the total cycle budget. Unused budget flows forward to subsequent legs in execution order, making the per-leg allocation a floor, not a ceiling.
public struct CycleBudget: Sendable {
    public let total: Int

    /// Per-leg allocation as a fraction of total. Normalized to sum to 1.
    public let legWeights: [ReductionLeg: Double]

    public init(total: Int, legWeights: [ReductionLeg: Double]) {
        self.total = total
        self.legWeights = legWeights
    }

    /// Initial budget for a leg, before unused-budget forwarding.
    public func initialBudget(for leg: ReductionLeg) -> Int {
        Int(Double(total) * (legWeights[leg] ?? 0))
    }

    /// Default leg weights: branch 5%, contravariant 30%, deletion 30%, covariant 25%, redistribution 10%.
    public static func defaultWeights() -> [ReductionLeg: Double] {
        [
            .branch: 0.05,
            .contravariant: 0.30,
            .deletion: 0.30,
            .covariant: 0.25,
            .redistribution: 0.10,
        ]
    }
}
