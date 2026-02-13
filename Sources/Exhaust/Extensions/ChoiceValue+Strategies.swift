//
//  ChoiceValue+Strategies.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/7/2025.
//

extension ChoiceValue {
    var bitPattern64: UInt64 {
        switch self {
        case let .unsigned(uint):
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
        case let .unsigned(uint):
            uint
        case let .signed(value, _, _):
            value == Int64.min ? UInt64(Int64.max) + 1 : UInt64(abs(value))
        case let .floating(value, _, _):
            abs(value).bitPattern
        case let .character(char):
            char.bitPattern64
        }
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
    
    var boundaries: [ChoiceValue] {
        switch self {
        case .unsigned:
            return [UInt64.max]
                .map { ChoiceValue($0, tag: .uint64) }
        case .signed:
            return [Int64.min, Int64.max]
                .map { ChoiceValue($0, tag: .int64) }
        case .floating:
            // We'll lose the magical values here?
            return [
                Double.greatestFiniteMagnitude / 100000000,
                Double.greatestFiniteMagnitude / 10000000,
                Double.greatestFiniteMagnitude / 1000000,
                Double.greatestFiniteMagnitude / 100000,
                Double.greatestFiniteMagnitude / 10000,
                Double.greatestFiniteMagnitude / 1000,
                Double.greatestFiniteMagnitude / 100,
                Double.greatestFiniteMagnitude,
                -Double.greatestFiniteMagnitude,
                -Double.greatestFiniteMagnitude / 100,
                -Double.greatestFiniteMagnitude / 1000,
                -Double.greatestFiniteMagnitude / 10000,
                -Double.greatestFiniteMagnitude / 100000,
                -Double.greatestFiniteMagnitude / 1000000,
                -Double.greatestFiniteMagnitude / 10000000,
                -Double.greatestFiniteMagnitude / 100000000,
//                Double.nan,
//                Double.infinity
            ]
                .map { ChoiceValue($0, tag: .double) }
        case .character:
            // TODO: unicode band, invisible characters, etc (in a second tier?)
            return []
                .map { ChoiceValue.character($0) }
        }
    }
    
    func binary(for ranges: [ClosedRange<UInt64>], direction: ShrinkingDirection) -> [ChoiceValue] {
        switch self {
        case let .unsigned(value):
            var halvings = [UInt64]()
            switch direction {
            case .towardsLowerBound:
                var candidate = value / 2
                while candidate > ranges[0].lowerBound {
                    halvings.append(candidate)
                    candidate /= 2
                }
            case .towardsHigherBound:
                var candidate = value * 2
                while candidate < ranges[0].upperBound {
                    halvings.append(candidate)
                    candidate *= 2
                }
            }
            return halvings
                .map { ChoiceValue($0, tag: .uint64) }
        case let .signed(value, _, _):
            var halvings = [Int64]()
            switch direction {
            case .towardsLowerBound:
                guard value > 0 else {
                    return []
                }
                var candidate = value / 2
                while candidate > ranges[0].lowerBound {
                    halvings.append(candidate)
                    candidate /= 2
                }
            case .towardsHigherBound:
                var candidate = value * 2
                while candidate < ranges[0].upperBound {
                    halvings.append(candidate)
                    candidate *= 2
                }
            }
            return halvings
                .map { ChoiceValue($0, tag: .int64) }
        case let .floating(value, _, _):
            var halvings = [Double]()
            switch direction {
            case .towardsLowerBound:
                guard value > 0 else {
                    return []
                }
                var candidate = value / 2
                let bound = Double(bitPattern64: ranges[0].lowerBound)
                while candidate > bound {
                    halvings.append(candidate)
                    candidate /= 2
                }
            case .towardsHigherBound:
                let value = value == 0 ? 1 :value
                var candidate = value * 2
                let bound = Double(bitPattern64: ranges[0].upperBound)
                while candidate < bound {
                    halvings.append(candidate)
                    candidate *= 2
                }
            }
            return halvings
                .map { ChoiceValue($0, tag: .double) }
        case let .character(character):
            guard let range = ranges.first(where: { $0.contains(character.bitPattern64) }) else {
                return []
            }
            let uints = ChoiceValue.unsigned(character.bitPattern64).binary(for: [range], direction: direction)
            // TODO: A lot of indirection here
            return uints.map {
                ChoiceValue.character(Character(bitPattern64: $0.convertible.bitPattern64))
            }
        }
    }
    
    // Decreases or increases number by 10%
    func saturation(for ranges: [ClosedRange<UInt64>], direction: ShrinkingDirection) -> [ChoiceValue] {
        switch self {
        case let .unsigned(value):
            let max = 50
            var count = 0
            var values = [UInt64]()
            switch direction {
            case .towardsLowerBound:
                var candidate = (value / 10) * 9
                while count < max, candidate > ranges[0].lowerBound {
                    count += 1
                    values.append(candidate)
                    candidate = (candidate / 10) * 9
                }
            case .towardsHigherBound:
                var candidate = (value * 10) / 9
                while count < max, candidate < ranges[0].lowerBound {
                    count += 1
                    values.append(candidate)
                    candidate = (candidate * 10) / 9
                }
            }
            return values
                .map { ChoiceValue($0, tag: .uint64) }
        case let .signed(value, _, _):
            guard value != 0 else {
                return []
            }
            let max = 50
            var count = 0
            var values = [Int64]()
            switch direction {
            case .towardsLowerBound:
                var candidate = (value / 10) * 9
                while count < max, candidate > ranges[0].lowerBound {
                    count += 1
                    values.append(candidate)
                    candidate = (candidate / 10) * 9
                }
            case .towardsHigherBound:
                var candidate = (value * 10) / 9
                while count < max, candidate < ranges[0].lowerBound {
                    count += 1
                    values.append(candidate)
                    candidate = (candidate * 10) / 9
                }
            }
            return values
                .map { ChoiceValue($0, tag: .int64) }
        case let .floating(value, _, _):
            guard value != 0 else {
                return []
            }
            let max = 50
            var count = 0
            var values = [Double]()
            switch direction {
            case .towardsLowerBound:
                let bound = Double(bitPattern64: ranges[0].lowerBound)
                var candidate = (value / 10) * 9
                while count < max, candidate > bound {
                    count += 1
                    values.append(candidate)
                    candidate = (candidate / 10) * 9
                }
            case .towardsHigherBound:
                let bound = Double(bitPattern64: ranges[0].upperBound)
                var candidate = (value * 10) / 9
                while count < max, candidate < bound {
                    count += 1
                    values.append(candidate)
                    candidate = (candidate * 10) / 9
                }
            }
            return values
                .map { ChoiceValue($0, tag: .double) }
        case let .character(character):
            guard let range = ranges.first(where: { $0.contains(character.bitPattern64) }) else {
                return []
            }
            let uints = ChoiceValue.unsigned(character.bitPattern64).saturation(for: [range], direction: direction)
            // TODO: A lot of indirection here
            return uints.map {
                ChoiceValue.character(Character(bitPattern64: $0.convertible.bitPattern64))
            }
        }
    }
    
    func ultraSaturation(for ranges: [ClosedRange<UInt64>], direction: ShrinkingDirection) -> [ChoiceValue] {
        switch self {
        case let .unsigned(value):
            guard value > 0 else {
                return []
            }
            var values = [UInt64]()
            let limit = 50
            var count = 0
            switch direction {
            case .towardsLowerBound:
                let bound = ranges[0].lowerBound
                var candidate = value - 1
                while count < limit, candidate > bound {
                    values.append(candidate)
                    candidate -= 1
                    count += 1
                }
            case .towardsHigherBound:
                let bound = ranges[0].upperBound
                var candidate = value + 1
                while count < limit, candidate < bound {
                    values.append(candidate)
                    candidate += 1
                    count += 1
                }
            }
            return values
                .map { ChoiceValue($0, tag: .uint64) }
        case let .signed(value, _, _):
            var values = [Int64]()
            let limit = 50
            var count = 0
            switch direction {
            case .towardsLowerBound:
                let bound = ranges[0].lowerBound
                var candidate = value - 1
                while count < limit, candidate > bound {
                    values.append(candidate)
                    candidate -= 1
                    count += 1
                }
            case .towardsHigherBound:
                let bound = ranges[0].upperBound
                var candidate = value + 1
                while count < limit, candidate < bound {
                    values.append(candidate)
                    candidate += 1
                    count += 1
                }
            }
            return values
                .map { ChoiceValue($0, tag: .int64) }
        case let .floating(value, _, _):
            var values = [Double]()
            let limit = 50
            var count = 0
            switch direction {
            case .towardsLowerBound:
                let bound = Double(bitPattern64: ranges[0].lowerBound)
                var candidate = value - 0.1
                while count < limit, candidate > bound {
                    values.append(candidate)
                    candidate -= 0.1
                    count += 1
                }
            case .towardsHigherBound:
                let bound = Double(bitPattern64: ranges[0].upperBound)
                var candidate = value + 0.1
                while count < limit, candidate < bound {
                    values.append(candidate)
                    candidate += 0.1
                    count += 1
                }
            }
            return values
                .map { ChoiceValue($0, tag: .double) }
        case let .character(character):
            guard let range = ranges.first(where: { $0.contains(character.bitPattern64) }) else {
                return []
            }
            let uints = ChoiceValue.unsigned(character.bitPattern64).ultraSaturation(for: [range], direction: direction)
            // TODO: A lot of indirection here
            return uints.map {
                ChoiceValue.character(Character(bitPattern64: $0.convertible.bitPattern64))
            }
        }
    }
}
