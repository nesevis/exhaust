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
        guard let index = drawIndex(
            from: choices, totalWeight: totalWeight, using: &prng
        ) else {
            return nil
        }
        return choices[index]
    }

    /// Draws the index of a single ``ReflectiveOperation/PickTuple`` proportional to its weight, or returns `nil` if total weight is zero.
    ///
    /// The walk reads only `weight`, so it addresses the array in place instead of iterating it by element. A ``ReflectiveOperation/PickTuple`` carries a generator and an exhaustion callback, both reference counted, so a by-element walk retains and releases every branch it passes to reach the one it selects. Callers that need the whole tuple go through ``draw(from:totalWeight:using:)``, which copies exactly the selected one.
    package static func drawIndex(
        from choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        totalWeight: UInt64,
        using prng: inout Xoshiro256
    ) -> Int? {
        guard totalWeight > 0 else { return nil }
        var roll = prng.next(upperBound: totalWeight) &+ 1
        for index in 0 ..< choices.count {
            let weight = choices[index].weight
            if roll <= weight {
                return index
            }
            let (remaining, underflow) = roll.subtractingReportingOverflow(weight)
            if underflow {
                return index
            }
            roll = remaining
        }
        // Only reached when totalWeight overstates the true sum; never return a zero-weight (unreachable) branch.
        return choices.lastIndex(where: { $0.weight > 0 })
    }
}
