//
//  ChoiceValue.swift
//  Exhaust
//
//  Created by Chris Kolbu on 20/7/2025.
//

@_spi(ExhaustInternal) public enum ChoiceValue: Comparable, Hashable, Equatable, Sendable {
    case unsigned(UInt64, any BitPatternConvertible.Type)
    /// The UInt64 represents its hashable behaviour
    case signed(Int64, UInt64, any BitPatternConvertible.Type)
    case floating(Double, UInt64, any BitPatternConvertible.Type)
    case character(Character)

    init(_ value: any BitPatternConvertible, tag: TypeTag) {
        switch tag {
        case .uint:
            self = .unsigned(value.bitPattern64, UInt.self)
        case .uint64:
            self = .unsigned(value.bitPattern64, UInt64.self)
        case .uint32:
            self = .unsigned(value.bitPattern64, UInt32.self)
        case .uint16:
            self = .unsigned(value.bitPattern64, UInt16.self)
        case .uint8:
            self = .unsigned(value.bitPattern64, UInt8.self)
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

    /// The semantically simplest value for a human reader.
    /// - Unsigned integers: 0
    /// - Signed integers: 0
    /// - Floating point: 0.0
    /// - Characters: "a"
    var semanticSimplest: ChoiceValue {
        switch self {
        case let .unsigned(_, type):
            return .init(type.init(bitPattern64: 0), tag: tag)
        case let .signed(_, _, type):
            let zeroBitPattern: UInt64
            if type is Int8.Type {
                zeroBitPattern = Int8(0).bitPattern64
            } else if type is Int16.Type {
                zeroBitPattern = Int16(0).bitPattern64
            } else if type is Int32.Type {
                zeroBitPattern = Int32(0).bitPattern64
            } else if type is Int64.Type {
                zeroBitPattern = Int64(0).bitPattern64
            } else if type is Int.Type {
                zeroBitPattern = Int(0).bitPattern64
            } else {
                return self
            }
            return .signed(0, zeroBitPattern, type)
        case let .floating(_, _, type):
            let zeroBitPattern: UInt64
            if type is Float.Type {
                zeroBitPattern = Float(0).bitPattern64
            } else if type is Double.Type {
                zeroBitPattern = Double(0).bitPattern64
            } else {
                return self
            }
            return .floating(0.0, zeroBitPattern, type)
        case .character:
            // Space is ascii 32
            return .character(" ")
        }
    }

    var tag: TypeTag {
        switch self {
        case let .unsigned(_, type):
            type.tag
        case let .signed(_, _, type):
            type.tag
        case let .floating(_, _, type):
            type.tag
        case .character:
            .character
        }
    }

    var convertibleType: any BitPatternConvertible.Type {
        switch self {
        case let .unsigned(_, type):
            type
        case let .signed(_, _, type):
            type
        case let .floating(_, _, type):
            type
        case .character:
            Character.self
        }
    }

    var complexity: UInt64 {
        switch self {
        case let .unsigned(value, _):
            return value
        case let .signed(value, _, _):
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
        for range in ranges where range.contains(bitPattern64) {
            return true
        }
        return false
    }

    func displayRange(_ range: ClosedRange<UInt64>) -> String {
        switch self {
        case .unsigned:
            return range.description
        case let .signed(_, _, underlyingType):
            let lower = underlyingType.init(bitPattern64: range.lowerBound)
            let upper = underlyingType.init(bitPattern64: range.upperBound)
            return "\(lower)...\(upper)"
        case let .floating(_, _, underlyingType):
            let lower = underlyingType.init(bitPattern64: range.lowerBound)
            let upper = underlyingType.init(bitPattern64: range.upperBound)
            return "\(lower)...\(upper)"
        case .character:
            return "'\(Character(bitPattern64: range.lowerBound))'...'\(Character(bitPattern64: range.upperBound).description)'"
        }
    }

    var doubleValue: Double {
        switch self {
        case .unsigned:
            // Clamp?
            return Double(bitPattern64)
        case .signed:
            guard let this = convertible as? (any FixedWidthInteger) else {
                fatalError()
            }
            return Double(this)
        case .floating:
            guard let this = convertible as? (any BinaryFloatingPoint) else {
                fatalError()
            }
            return Double(this)
        case let .character(character):
            return Double(character.bitPattern64)
        }
    }

    @_spi(ExhaustInternal) public var convertible: any BitPatternConvertible {
        if case let .character(value) = self {
            return value
        }
        return convertibleType.init(bitPattern64: bitPattern64)
    }

    @_spi(ExhaustInternal) public func hash(into hasher: inout Hasher) {
        switch self {
        case let .unsigned(uInt64, _):
            hasher.combine(uInt64)
        case let .signed(_, uInt64, _):
            hasher.combine(uInt64)
        case let .floating(_, uInt64, _):
            hasher.combine(uInt64)
        case let .character(character):
            hasher.combine(character)
        }
        hasher.combine(tag)
    }

    @_spi(ExhaustInternal) public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hashValue == rhs.hashValue
    }

    @_spi(ExhaustInternal) public static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.unsigned, .unsigned):
            lhs.bitPattern64 < rhs.bitPattern64
        case let (.signed(lhsInt, _, _), .signed(rhsInt, _, _)):
            lhsInt < rhsInt
        case let (.floating(lhsDouble, _, _), .floating(rhsDouble, _, _)):
            lhsDouble < rhsDouble
        case (.character, .character):
            // TODO: If there are multiple unicode components use both?
            lhs.bitPattern64 < rhs.bitPattern64
        default:
            fatalError("Can't compare two different choice values!")
        }
    }
}
