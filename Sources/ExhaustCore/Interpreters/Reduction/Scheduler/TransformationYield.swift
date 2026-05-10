//
//  TransformationYield.swift
//  Exhaust
//

// MARK: - Transformation Yield

/// Packages structural yield, value yield, source distance, and estimated resource cost for a graph transformation.
///
/// The scheduler selects the maximum yield. Ordering: more structural reduction, then more value unlocked, then closer to target, then lower cost.
struct TransformationYield: Comparable, Equatable {
    /// Sequence positions removed. Zero for minimization, exchange, and permutation.
    let structural: Int

    /// Bound subtree size that reducing this value would structurally unlock. Zero for removal, replacement, exchange, and permutation.
    let value: Int

    /// Maximum distance any source value needs to travel to reach its reduction target. Zero for exact operations (removal, replacement, permutation, minimisation). Non-zero for approximate operations (exchange), where closer-to-target scopes are preferred.
    let maxSourceDistance: Int

    /// Expected number of probes the encoder will need.
    let estimatedProbes: Int

    /// Natural ordering: higher structural yield, then higher value yield, then closer to target, then lower cost.
    static func < (lhs: TransformationYield, rhs: TransformationYield) -> Bool {
        if lhs.structural != rhs.structural {
            return lhs.structural < rhs.structural
        }
        if lhs.value != rhs.value {
            return lhs.value < rhs.value
        }
        if lhs.maxSourceDistance != rhs.maxSourceDistance {
            return lhs.maxSourceDistance > rhs.maxSourceDistance
        }
        return lhs.estimatedProbes > rhs.estimatedProbes
    }
}
