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
            return [0, 1, 2]
                .map { ChoiceValue.unsigned($0) }
        case let .signed(_, mask):
            return [0, -1, 1, 2, -2]
                .map { ChoiceValue.signed($0.bitPattern64, mask) }
        case let .floating(_, mask):
            return [0, -0.1, -0.01, -0.001, -0.0001, 0.001, 0.01, 0.1]
                .map { ChoiceValue.floating($0.bitPattern, mask)}
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
                .map { ChoiceValue.unsigned($0) }
        case let .signed(_, mask):
            return [Int64.min, Int64.max]
                .map { ChoiceValue.signed($0.bitPattern64, mask) }
        case let .floating(_, mask):
            // We'll lose the magical values here?
            return [-Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, Double.ulpOfOne, Double.nan, Double.infinity]
                .map { ChoiceValue.floating($0.bitPattern, mask)}
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
                halvings.append(value - candidate)
                candidate /= 2
            }
            return halvings
                .map { ChoiceValue.unsigned($0) }
        case let .signed(value, mask):
            let signed = Int64(bitPattern64: value ^ mask)
            var halvings = [Int64]()
            var candidate = signed / 2
            while candidate > ranges[0].lowerBound {
                halvings.append(signed - candidate)
                candidate /= 2
            }
            return halvings
                .map { ChoiceValue.signed($0.bitPattern64, mask) }
        case let .floating(value, mask):
            let signed = Double(bitPattern64: value ^ mask)
            var halvings = [Double]()
            var candidate = signed / 2
            let lowerBound = Double(ranges[0].lowerBound)
            while candidate > lowerBound {
                halvings.append(signed - candidate)
                candidate /= 2
            }
            return halvings
                .map { ChoiceValue.floating($0.bitPattern64, mask) }
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
}
