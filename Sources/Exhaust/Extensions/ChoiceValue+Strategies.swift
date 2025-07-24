//
//  ChoiceValue+Strategies.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/7/2025.
//

extension ChoiceValue {
    var fundamentalValues: [ChoiceValue] {
        switch self {
        case .unsigned:
            return [UInt64(0), 1, 2]
                .map(ChoiceValue.init)
        case .signed:
            return [Int64(0), -1, 1, 2, -2]
                .map(ChoiceValue.init)
        case .floating:
            return [Double(0), -0.1, -0.01, -0.001, -Double.ulpOfOne, -0.0001, Double.ulpOfOne, 0.001, 0.01, 0.1]
                .map(ChoiceValue.init)
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
                .map(ChoiceValue.init)
        case .signed:
            return [Int64.min, Int64.max]
                .map(ChoiceValue.init)
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
                .map(ChoiceValue.init)
        case .character:
            // TODO: unicode band, invisible characters, etc (in a second tier?)
            return []
                .map { ChoiceValue.character($0) }
        }
    }
    
    func binary(for ranges: [ClosedRange<UInt64>]) -> [ChoiceValue] {
        switch self {
        case let .unsigned(value):
            var halvings = [UInt64]()
            var candidate = value / 2
            while candidate > ranges[0].lowerBound {
                halvings.append(candidate)
                candidate /= 2
            }
            return halvings
                .map(ChoiceValue.init)
        case let .signed(value, _):
            let signed = value
            var halvings = [Int64]()
            var candidate = signed / 2
            while candidate > ranges[0].lowerBound {
                halvings.append(candidate)
                candidate /= 2
            }
            return halvings
                .map(ChoiceValue.init)
        case let .floating(value, _):
            let signed = value
            var halvings = [Double]()
            var candidate = signed / 2
            let lowerBound = Double(ranges[0].lowerBound)
            while candidate > lowerBound {
                halvings.append(candidate)
                candidate /= 2
            }
            return halvings
                .map(ChoiceValue.init)
        case let .character(character):
            guard let range = ranges.first(where: { $0.contains(character.bitPattern64) }) else {
                return []
            }
            let uints = ChoiceValue.unsigned(character.bitPattern64).binary(for: [range])
            // TODO: A lot of indirection here
            return uints.map {
                ChoiceValue.character(Character(bitPattern64: $0.convertible.bitPattern64))
            }
        }
    }
    
    // Decreases number by 10%
    func saturation(for ranges: [ClosedRange<UInt64>]) -> [ChoiceValue] {
        switch self {
        case let .unsigned(value):
            guard value >= 10 else {
                return []
            }
            let max = 50
            var count = 0
            var decimation = [UInt64]()
            var candidate = value / 10 * 9
            while count < max, candidate > ranges[0].lowerBound {
                count += 1
                decimation.append(candidate)
                candidate = candidate / 10 * 9
            }
            return decimation
                .map(ChoiceValue.init)
        case let .signed(value, _):
            let max = 50
            var count = 0
            let signed = value
            var decimation = [Int64]()
            let lowerBound = Int64(bitPattern64: ranges[0].lowerBound)
            var candidate = signed / 10 * 9
            while count < max, candidate > lowerBound {
                count += 1
                decimation.append(candidate)
                candidate = candidate / 10 * 9
            }
            return decimation
                .map(ChoiceValue.init)
        case let .floating(value, _):
            let max = 50
            var count = 0
            let signed = value
            let lowerBound = Double(bitPattern64: ranges[0].lowerBound)
            var halvings = [Double]()
            var candidate = value / 10 * 9
            while count < max, candidate > lowerBound {
                count += 1
                halvings.append(candidate)
                candidate = candidate / 10 * 9
            }
            return halvings
                .map(ChoiceValue.init)
        case let .character(character):
            guard let range = ranges.first(where: { $0.contains(character.bitPattern64) }) else {
                return []
            }
            let uints = ChoiceValue.unsigned(character.bitPattern64).saturation(for: [range])
            // TODO: A lot of indirection here
            print()
            return uints.map {
                ChoiceValue.character(Character(bitPattern64: $0.convertible.bitPattern64))
            }
        }
    }
    
    func ultraSaturation(for ranges: [ClosedRange<UInt64>]) -> [ChoiceValue] {
        let limit = 50
        switch self {
        case let .unsigned(value):
            guard value > 0 else {
                return []
            }
            var values = [UInt64]()
            var candidate = value - 1
            let lowerBound = ranges[0].lowerBound
            var count = 0
            while count < limit, candidate > lowerBound {
                values.append(candidate)
                candidate -= 1
                count += 1
            }
            return values
                .map(ChoiceValue.init)
        case let .signed(value, _):
            let signed = value
            var values = [Int64]()
            var candidate = signed - 1
            let lowerBound = Int64(bitPattern: ranges[0].lowerBound)
            var count = 0
            while count < limit, candidate > lowerBound {
                values.append(candidate)
                candidate -= 1
                count += 1
            }
            return values
                .map(ChoiceValue.init)
        case let .floating(value, _):
            let signed = value
            var values = [Double]()
            var candidate = signed - 0.1
            let lowerBound = Double(bitPattern: ranges[0].lowerBound)
            var count = 0
            while count < limit, candidate > lowerBound {
                values.append(candidate)
                candidate -= 0.1
                count += 1
            }
            return values
                .map(ChoiceValue.init)
        case let .character(character):
            guard let range = ranges.first(where: { $0.contains(character.bitPattern64) }) else {
                return []
            }
            let uints = ChoiceValue.unsigned(character.bitPattern64).ultraSaturation(for: [range])
            // TODO: A lot of indirection here
            print()
            return uints.map {
                ChoiceValue.character(Character(bitPattern64: $0.convertible.bitPattern64))
            }
        }
    }
}
