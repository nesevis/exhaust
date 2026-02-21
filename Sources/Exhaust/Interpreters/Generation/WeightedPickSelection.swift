//
//  WeightedPickSelection.swift
//  Exhaust
//
//  Created by Codex on 21/2/2026.
//

import Foundation

enum WeightedPickSelection {
    @inline(__always)
    static func draw(
        from choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        using prng: inout Xoshiro256,
    ) -> ReflectiveOperation.PickTuple? {
        let totalWeight = choices.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else {
            return nil
        }
        var roll = UInt64.random(in: 1 ... totalWeight, using: &prng)
        for choice in choices {
            if roll <= choice.weight {
                return choice
            }
            roll -= choice.weight
        }
        return nil
    }
}
