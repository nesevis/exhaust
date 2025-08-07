//
//  Choice.swift
//  Exhaust
//
//  Created by Chris Kolbu on 20/7/2025.
//

public enum ChoiceValue: Comparable, Hashable, Equatable, Sendable {
    case unsigned(UInt64)
    /// The UInt64 represents its hashable behaviour
    case signed(Int64, UInt64)
    case floating(Double, UInt64)
    case character(Character)

    // Make shrinkable?
    // 0 returns Int even when we want UInt
    init(_ value: any BitPatternConvertible) {
        switch value {
        case is Double:
            self = .floating(Double(bitPattern64: value.bitPattern64), value.bitPattern64)
        case is Float:
            self = .floating(Double(Float(bitPattern64: value.bitPattern64)), value.bitPattern64)
        case is Int:
            self = .signed(Int64(Int(bitPattern64: value.bitPattern64)), value.bitPattern64)
        case is Int64:
            self = .signed(Int64(bitPattern64: value.bitPattern64), value.bitPattern64)
        case is Int32:
            self = .signed(Int64(Int32(bitPattern64: value.bitPattern64)), value.bitPattern64)
        case is Int16:
            self = .signed(Int64(Int16(bitPattern64: value.bitPattern64)), value.bitPattern64)
        case is Int8:
            self = .signed(Int64(Int8(bitPattern64: value.bitPattern64)), value.bitPattern64)
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
            let absValue = abs(value)
            if absValue >= Double(UInt64.max) {
                return UInt64.max
            }
            // Complexity does not handle values below 1
            if absValue.isNaN || absValue.isInfinite {
                return UInt64.max
            }
            return UInt64(absValue)
        case let .character(character):
            return character.bitPattern64 + 100 // Encourages removing '\0' bits
        }
    }
    
    func fits(in ranges: [ClosedRange<UInt64>]) -> Bool {
        for range in ranges {
            if range.contains(bitPattern64) {
                return true
            }
        }
        return false
    }

    public var convertible: any BitPatternConvertible {
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
    
    // The case here is that `self` failed the property and `other` passed, so they represent both the range and the direction between them
    func shrinkingDirection(given other: Self) -> ShrinkingDirection {
        switch (self, other) {
        case let (.unsigned(lhs), .unsigned(rhs)):
            return lhs <= rhs ? .towardsHigherBound : .towardsLowerBound
        case let (.signed(lhs, _), .signed(rhs, _)):
            return lhs <= rhs ? .towardsHigherBound : .towardsLowerBound
        case let (.floating(lhs, _), .floating(rhs, _)):
            return lhs <= rhs ? .towardsHigherBound : .towardsLowerBound
        case let (.character(lhs), .character(rhs)):
            return lhs <= rhs ? .towardsHigherBound : .towardsLowerBound
        default:
            fatalError("\(#function) should not compare different types!")
        }
    }
    
    public func hash(into hasher: inout Hasher) {
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
    
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hashValue == rhs.hashValue
    }
    
    public static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.unsigned, .unsigned), (.signed, .signed), (.floating, .floating), (.character, .character):
            // The bitpattern64 representation is sequential across all types
            return lhs.bitPattern64 < rhs.bitPattern64
        default:
            fatalError("Can't compare two different choice values!")
        }
    }
}
