//
//  WeightedPickSelection.swift
//  Exhaust
//
//  Created by Codex on 21/2/2026.
//

/// Selects a branch from a weighted pick operation using cumulative-sum binary search over the weight array.
package enum WeightedPickSelection {
    /// Draws a single ``ReflectiveOperation/PickTuple`` proportional to its weight, or returns `nil` if total weight is zero.
    public static func draw(
        from choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        using prng: inout Xoshiro256
    ) -> ReflectiveOperation.PickTuple? {
        var totalWeight: UInt64 = 0
        for choice in choices {
            let (newTotal, overflow) = totalWeight.addingReportingOverflow(choice.weight)
            if overflow {
                totalWeight = UInt64.max
                break
            }
            totalWeight = newTotal
        }
        guard totalWeight > 0 else {
            return nil
        }
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
        return choices.last
    }
}
