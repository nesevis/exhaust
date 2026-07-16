//
//  DispatchPriority.swift
//  Exhaust
//

// MARK: - Dispatch Priority

/// Scheduling priority for a graph transformation candidate.
///
/// The scheduler dispatches the highest-priority candidate first. Ordering: more structural reduction, then more value unlocked, then smaller reduction magnitude remaining, then lower cost.
struct DispatchPriority: Comparable, Equatable {
    /// Estimated sequence positions removed. Zero for minimization, exchange, and permutation.
    let structuralBenefit: Int

    /// Bound subtree size that reducing this value would structurally unlock. Zero for removal, replacement, exchange, and permutation.
    let valueBenefit: Int

    /// Maximum value-space distance any source leaf must traverse to reach its reduction target. Zero for exact operations (removal, replacement, permutation, minimization). Non-zero for approximate operations (exchange), where closer-to-target candidates are preferred.
    let reductionMagnitude: Int

    /// Expected number of probes the encoder will need.
    let estimatedCost: Int

    /// Natural ordering: higher structural benefit, then higher value benefit, then smaller reduction magnitude, then lower cost.
    static func < (lhs: DispatchPriority, rhs: DispatchPriority) -> Bool {
        if lhs.structuralBenefit != rhs.structuralBenefit {
            return lhs.structuralBenefit < rhs.structuralBenefit
        }
        if lhs.valueBenefit != rhs.valueBenefit {
            return lhs.valueBenefit < rhs.valueBenefit
        }
        if lhs.reductionMagnitude != rhs.reductionMagnitude {
            return lhs.reductionMagnitude > rhs.reductionMagnitude
        }
        return lhs.estimatedCost > rhs.estimatedCost
    }
}
