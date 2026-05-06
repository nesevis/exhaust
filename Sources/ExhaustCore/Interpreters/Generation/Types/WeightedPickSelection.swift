//
//  WeightedPickSelection.swift
//  Exhaust
//
//  Created by Codex on 21/2/2026.
//


package enum WeightedPickSelection {
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
            roll -= choice.weight
        }
        return nil
    }
}
