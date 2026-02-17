//
//  ChoiceValue+Strategies.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/7/2025.
//

extension ChoiceValue {
    var bitPattern64: UInt64 {
        switch self {
        case let .unsigned(uint, _):
            uint
        case let .signed(_, uint, _):
            uint
        case let .floating(_, uint, _):
            uint
        case let .character(char):
            char.bitPattern64
        }
    }

    /// Key for shortlex ordering where values closer to zero are smaller.
    /// - Signed integers: absolute value (0 → 0, ±1 → 1, ±2 → 2, ...)
    /// - Floating point: absolute value's raw IEEE 754 bit pattern (0.0 → 0, ±small → small, ±large → large)
    /// - Unsigned integers and characters: identical to `bitPattern64`
    var shortlexKey: UInt64 {
        switch self {
        case let .unsigned(uint, _):
            uint
        case let .signed(value, _, _):
//            value == Int64.min ? UInt64(Int64.max) + 1 : UInt64(abs(value))
            UInt64(bitPattern: (value << 1) ^ (value >> 63))
        case let .floating(value, _, _):
            abs(value).bitPattern
        case let .character(char):
            char.bitPattern64
        }
    }

    /// The bit pattern of the ideal shrink target for this value type.
    /// - Unsigned/Character: lowest valid bit pattern (smallest value)
    /// - Signed/Float: 0's bit pattern if in range, else the range bound closest to 0's bit pattern
    func reductionTarget(in ranges: [ClosedRange<UInt64>]) -> UInt64 {
        let target = semanticSimplest.bitPattern64
        if fits(in: ranges, bitPattern: target) {
            return target
        }
        // Find the range bound closest to the target
        var bestBound = ranges[0].lowerBound
        var bestDistance = target > bestBound
            ? target - bestBound
            : bestBound - target
        for range in ranges {
            for bound in [range.lowerBound, range.upperBound] {
                let distance = target > bound
                    ? target - bound
                    : bound - target
                if distance < bestDistance {
                    bestDistance = distance
                    bestBound = bound
                }
            }
        }
        return bestBound
    }

    private func fits(in ranges: [ClosedRange<UInt64>], bitPattern: UInt64) -> Bool {
        for range in ranges {
            if range.contains(bitPattern) {
                return true
            }
        }
        return false
    }

    var fundamentalValues: [ChoiceValue] {
        switch self {
        case .unsigned:
            let values: [UInt64] = [0, 1, 2]
            return values
                .map { ChoiceValue($0, tag: .uint64) }
        case .signed:
            let values: [Int64] = [0, -1, 1, 2, -2]
            return values
                .map { ChoiceValue($0, tag: .int64) }
        case .floating:
            let values: [Double] = [0, -0.1, -0.01, -0.001, -Double.ulpOfOne, -0.0001, Double.ulpOfOne, 0.001, 0.01, 0.1]
            return values
                .map { ChoiceValue($0, tag: .double) }
        case .character:
            // TODO: unicode band, invisible characters, etc (in a second tier?)
            // [ "a", "b", "c", "A", "B", "C", "1", "2", "3", "\n", " " ]
            return [" ", "a", "b", "c", "A", "B", "C", "0", "1", "2", "3", "\n", "\0"]
                .map { ChoiceValue.character($0) }
        }
    }
}
