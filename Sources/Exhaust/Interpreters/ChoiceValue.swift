//
//  Choice.swift
//  Exhaust
//
//  Created by Chris Kolbu on 20/7/2025.
//

enum ChoiceValue: Comparable, Hashable, Equatable {
    case unsigned(UInt64)
    /// The UInt64 represents its hashable behaviour
    case signed(Int64, UInt64)
    case floating(Double, UInt64)
    case character(Character)

    // Make shrinkable?
    // 0 returns Int even when we want UInt
    init(_ value: any BitPatternConvertible) {
        switch value {
        case is Double, is Float:
            self = .floating(Double(bitPattern64: value.bitPattern64), value.bitPattern64)
        case is Int64, is Int32, is Int16, is Int8, is Int:
            self = .signed(Int64(bitPattern64: value.bitPattern64), value.bitPattern64)
        case is Character:
            self = .character(value as! Character)
        default:
            self = .unsigned(value.bitPattern64)
        }
    }
    
    var complexity: UInt64 {
        switch self {
        case let .unsigned(value):
            return value
        case let .signed(value, bitPattern):
            if bitPattern == 0 {
                return bitPattern
            }
            return UInt64(abs(value))
        case let .floating(value, _):
            let absValue = abs(value) * 100
            if absValue >= Double(UInt64.max) {
                return UInt64.max
            }
            // Complexity does not handle values below 1
            return UInt64(absValue)
        case let .character(character):
            return character.bitPattern64 + 100 // Encourages removing '\0' bits
        }
    }
    
    func fits(in ranges: [ClosedRange<UInt64>]) -> Bool {
        for range in ranges {
            switch self {
            case .unsigned(let uInt64):
                if range.contains(uInt64) {
                    return true
                }
            case .signed(let int64, _):
                let lower = Int64(bitPattern64: range.lowerBound)
                let upper = Int64(bitPattern64: range.upperBound)
                if int64 >= lower && int64 <= upper {
                    return true
                }
            case .floating(let double, _):
                let lower = Double(bitPattern64: range.lowerBound)
                let upper = Double(bitPattern64: range.upperBound)
                if double >= lower && double <= upper {
                    return true
                }
            case .character(let character):
                if range.contains(character.bitPattern64) {
                    return true
                }
            }
        }
        return false
    }

    var convertible: any BitPatternConvertible {
        switch self {
        case .unsigned(let uInt64):
            return uInt64
        case .signed(let int64, _):
            return int64
        case .floating(let double, _):
            return double
        case .character(let character):
            return character
        }
    }
    
    func hash(into hasher: inout Hasher) {
        switch self {
        case .unsigned(let uInt64):
            hasher.combine(uInt64)
        case .signed(_, let uInt64):
            hasher.combine(uInt64)
        case .floating(_, let uInt64):
            hasher.combine(uInt64)
        case .character(let character):
            hasher.combine(character)
        }
    }
    
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hashValue == rhs.hashValue
    }
}
