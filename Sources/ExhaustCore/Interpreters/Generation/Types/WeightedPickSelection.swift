//
//  WeightedPickSelection.swift
//  Exhaust
//
//  Created by Codex on 21/2/2026.
//

/// Selects a branch from a weighted pick operation using cumulative-sum walk over the weight array.
package enum WeightedPickSelection {
    /// Draws a single ``ReflectiveOperation/PickTuple`` proportional to its weight, or returns `nil` if total weight is zero.
    public static func draw(
        from choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        totalWeight: UInt64,
        using prng: inout Xoshiro256
    ) -> ReflectiveOperation.PickTuple? {
        guard totalWeight > 0 else { return nil }
        var roll = prng.next(upperBound: totalWeight) &+ 1
        for choice in choices {
            if roll <= choice.weight {
                return choice
            }
            let (remaining, underflow) = roll.subtractingReportingOverflow(choice.weight)
            if underflow {
                return choice
            }
            roll = remaining
        }
        // Only reached when totalWeight overstates the true sum; never return a zero-weight (unreachable) branch.
        return choices.last(where: { $0.weight > 0 })
    }
}
