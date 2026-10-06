//
//  RelationQuery.swift
//  Exhaust
//

// MARK: - Relation Scope Query

/// Static scope builder for relation search over stall-converged leaf pairs.
///
/// The stall gate is the whole design: a pair is eligible only when both leaves carry a convergence record equal to their current bit pattern while sitting above their reduction targets. Value search produces that state exactly when no single-leaf reduction exists, so the query fires after every cheaper move has been certified futile, and it can never displace an encoder that still has work. On uncoupled workloads leaves converge at their targets or keep moving, so the gate stays closed.
///
/// The relation is inferred in semantic-magnitude space, not bit-pattern space: signed integers use an XOR sign-magnitude encoding where the pattern of a small positive value is the sign-bit mask plus the value, so a ratio between raw patterns is meaningless. Each leaf's magnitude is its distance above the semantic-zero pattern, which recovers the value-space ratio for every integer tag.
enum RelationQuery {
    /// Upper bound on the reduced ratio components. A pair whose reduced numerator or denominator exceeds this is treated as unrelated: large components mean the current magnitudes share only an incidental divisor, and probing along that line would waste the budget on a relation the generator almost certainly does not encode.
    static let ratioCap: UInt64 = 16

    /// Builds the relation scope from stall-converged integer leaves, or nil when no eligible pair exists.
    static func build(graph: ChoiceGraph) -> RelationScope? {
        var cursor = RelationPairCursor(graph: graph)
        var pairs: [RelationPair] = []
        while pairs.count < GraphRedistributionEncoder.maxPairsPerScope, let pair = cursor.next() {
            pairs.append(pair)
        }

        guard pairs.isEmpty == false else {
            return nil
        }
        return RelationScope(pairs: pairs)
    }
}
