//
//  ChoiceValue.swift
//  Exhaust
//
//  Created by Chris Kolbu on 20/7/2025.
//

public enum ChoiceValue: Comparable, Hashable, Equatable, Sendable {
    case unsigned(UInt64)
    /// The UInt64 represents its hashable behaviour
    case signed(Int64, UInt64, any BitPatternConvertible.Type)
    case floating(Double, UInt64, any BitPatternConvertible.Type)
    case character(Character)
    
    init(_ value: any BitPatternConvertible, tag: TypeTag) {
        switch tag {
        case .uint, .uint64, .uint32, .uint16, .uint8:
            self = .unsigned(value.bitPattern64)
        case .int:
            self = .signed(Int64(Int(bitPattern64: value.bitPattern64)), value.bitPattern64, Int.self)
        case .int64:
            self = .signed(Int64(bitPattern64: value.bitPattern64), value.bitPattern64, Int64.self)
        case .int32:
            self = .signed(Int64(Int32(bitPattern64: value.bitPattern64)), value.bitPattern64, Int32.self)
        case .int16:
            self = .signed(Int64(Int16(bitPattern64: value.bitPattern64)), value.bitPattern64, Int16.self)
        case .int8:
            self = .signed(Int64(Int8(bitPattern64: value.bitPattern64)), value.bitPattern64, Int8.self)
        case .double:
            self = .floating(Double(bitPattern64: value.bitPattern64), value.bitPattern64, Double.self)
        case .float:
            self = .floating(Double(Float(bitPattern64: value.bitPattern64)), value.bitPattern64, Float.self)
        case .character:
            if let character = value as? Character {
                self = .character(character)
            } else {
                self = .character(Character(bitPattern64: value.bitPattern64))
            }
        }
    }

    var complexity: UInt64 {
        switch self {
        case let .unsigned(value):
            return value
        case let .signed(value, bitPattern, _):
            if bitPattern == 0 {
                return bitPattern
            }
            return UInt64(abs(value))
        case let .floating(value, _, _):
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
    
    func displayRange(_ range: ClosedRange<UInt64>) -> String {
        switch self {
        case .unsigned:
            return range.description
        case .signed(_, _, let underlyingType):
            let lower = underlyingType.init(bitPattern64: range.lowerBound)
            let upper = underlyingType.init(bitPattern64: range.upperBound)
            return "\(lower)...\(upper)"
        case .floating(_, _, let underlyingType):
            let lower = underlyingType.init(bitPattern64: range.lowerBound)
            let upper = underlyingType.init(bitPattern64: range.upperBound)
            return "\(lower)...\(upper)"
        case .character:
            return (Character(bitPattern64: range.lowerBound)...Character(bitPattern64: range.upperBound)).description
        }
    }
    
    var doubleValue: Double {
        switch self {
        case .unsigned(let uInt64):
            // Clamp?
            return Double(uInt64)
        case .signed(_, let uint64, let underlyingType):
            guard let value = underlyingType.init(bitPattern64: uint64) as? (any FixedWidthInteger) else {
                fatalError()
            }
            return Double(value)
        case .floating(_, let uint64, let underlyingType):
            guard let value = underlyingType.init(bitPattern64: uint64) as? (any BinaryFloatingPoint) else {
                fatalError()
            }
            return Double(value)
        case .character(let character):
            return Double(character.bitPattern64)
        }
    }

    public var convertible: any BitPatternConvertible {
        switch self {
        case .unsigned(let uInt64):
            return uInt64
        case .signed(let int64, _, _):
            return int64
        case .floating(let double, _, _):
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
        case let (.signed(lhs, _, _), .signed(rhs, _, _)):
            return lhs <= rhs ? .towardsHigherBound : .towardsLowerBound
        case let (.floating(lhs, _, _), .floating(rhs, _, _)):
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
        case .signed(_, let uInt64, _):
            hasher.combine(uInt64)
        case .floating(_, let uInt64, _):
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
