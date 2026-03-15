//
//  WeightedPickSelection.swift
//  Exhaust
//
//  Created by Codex on 21/2/2026.
//

import Foundation

public enum WeightedPickSelection {
    @inline(__always)
    public static func draw(
        from choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        using prng: inout Xoshiro256
    ) -> ReflectiveOperation.PickTuple? {
        let totalWeight = choices.reduce(0) { $0 + $1.weight }
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
