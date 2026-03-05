//
//  ChoiceValue.swift
//  Exhaust
//
//  Created by Chris Kolbu on 20/7/2025.
//

@_spi(ExhaustInternal) public enum ChoiceValue: Comparable, Hashable, Equatable, Sendable {
    case unsigned(UInt64, TypeTag)
    /// The UInt64 represents its hashable behaviour
    case signed(Int64, UInt64, TypeTag)
    case floating(Double, UInt64, TypeTag)

    @_spi(ExhaustInternal) public init(_ value: any BitPatternConvertible, tag: TypeTag) {
        switch tag {
        case .uint:
            self = .unsigned(value.bitPattern64, .uint)
        case .uint64:
            self = .unsigned(value.bitPattern64, .uint64)
        case .uint32:
            self = .unsigned(value.bitPattern64, .uint32)
        case .uint16:
            self = .unsigned(value.bitPattern64, .uint16)
        case .uint8:
            self = .unsigned(value.bitPattern64, .uint8)
        case .int:
            self = .signed(Int64(Int(bitPattern64: value.bitPattern64)), value.bitPattern64, .int)
        case .int64:
            self = .signed(Int64(bitPattern64: value.bitPattern64), value.bitPattern64, .int64)
        case .int32:
            self = .signed(Int64(Int32(bitPattern64: value.bitPattern64)), value.bitPattern64, .int32)
        case .int16:
            self = .signed(Int64(Int16(bitPattern64: value.bitPattern64)), value.bitPattern64, .int16)
        case .int8:
            self = .signed(Int64(Int8(bitPattern64: value.bitPattern64)), value.bitPattern64, .int8)
        case .double:
            self = .floating(Double(bitPattern64: value.bitPattern64), value.bitPattern64, .double)
        case .float:
            self = .floating(Double(Float(bitPattern64: value.bitPattern64)), value.bitPattern64, .float)
        }
    }

    /// The semantically simplest value for a human reader.
    /// - Unsigned integers: 0
    /// - Signed integers: 0
    /// - Floating point: 0.0
    @_spi(ExhaustInternal) public var semanticSimplest: ChoiceValue {
        switch self {
        case let .unsigned(_, tag):
            return .unsigned(0, tag)
        case let .signed(_, _, tag):
            let zeroBitPattern: UInt64 = switch tag {
            case .int8: Int8(0).bitPattern64
            case .int16: Int16(0).bitPattern64
            case .int32: Int32(0).bitPattern64
            case .int64: Int64(0).bitPattern64
            case .int: Int(0).bitPattern64
            default: fatalError("Unexpected tag \(tag) for signed ChoiceValue")
            }
            return .signed(0, zeroBitPattern, tag)
        case let .floating(_, _, tag):
            let zeroBitPattern: UInt64 = switch tag {
            case .float: Float(0).bitPattern64
            case .double: Double(0).bitPattern64
            default: fatalError("Unexpected tag \(tag) for floating ChoiceValue")
            }
            return .floating(0.0, zeroBitPattern, tag)
        }
    }

    var tag: TypeTag {
        switch self {
        case let .unsigned(_, tag): tag
        case let .signed(_, _, tag): tag
        case let .floating(_, _, tag): tag
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
        }
    }

    func fits(in range: ClosedRange<UInt64>?) -> Bool {
        guard let range else { return true }
        return range.contains(bitPattern64)
    }

    func displayRange(_ range: ClosedRange<UInt64>) -> String {
        switch self {
        case .unsigned:
            return range.description
        case let .signed(_, _, tag):
            let lower = tag.makeConvertible(bitPattern64: range.lowerBound)
            let upper = tag.makeConvertible(bitPattern64: range.upperBound)
            return "\(lower)...\(upper)"
        case let .floating(_, _, tag):
            let lower = tag.makeConvertible(bitPattern64: range.lowerBound)
            let upper = tag.makeConvertible(bitPattern64: range.upperBound)
            return "\(lower)...\(upper)"
        }
    }

    var doubleValue: Double {
        switch self {
        case .unsigned:
            return Double(bitPattern64)
        case let .signed(_, _, tag):
            switch tag {
            case .int8: return Double(Int8(bitPattern64: bitPattern64))
            case .int16: return Double(Int16(bitPattern64: bitPattern64))
            case .int32: return Double(Int32(bitPattern64: bitPattern64))
            case .int64: return Double(Int64(bitPattern64: bitPattern64))
            case .int: return Double(Int(bitPattern64: bitPattern64))
            default: fatalError("Unexpected tag \(tag) for signed ChoiceValue")
            }
        case let .floating(value, _, _):
            return value
        }
    }

    @_spi(ExhaustInternal) public var convertible: any BitPatternConvertible {
        tag.makeConvertible(bitPattern64: bitPattern64)
    }

    @_spi(ExhaustInternal) public func hash(into hasher: inout Hasher) {
        switch self {
        case let .unsigned(uInt64, _):
            hasher.combine(uInt64)
        case let .signed(_, uInt64, _):
            hasher.combine(uInt64)
        case let .floating(_, uInt64, _):
            hasher.combine(uInt64)
        }
        hasher.combine(tag)
    }

    @_spi(ExhaustInternal) public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.tag == rhs.tag else { return false }
        return switch (lhs, rhs) {
        case let (.unsigned(lhsValue, _), .unsigned(rhsValue, _)):
            lhsValue == rhsValue
        case let (.signed(_, lhsBits, _), .signed(_, rhsBits, _)):
            lhsBits == rhsBits
        case let (.floating(_, lhsBits, _), .floating(_, rhsBits, _)):
            lhsBits == rhsBits
        default:
            false
        }
    }

    @_spi(ExhaustInternal) public static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.unsigned, .unsigned):
            lhs.bitPattern64 < rhs.bitPattern64
        case let (.signed(lhsInt, _, _), .signed(rhsInt, _, _)):
            lhsInt < rhsInt
        case let (.floating(lhsDouble, _, _), .floating(rhsDouble, _, _)):
            lhsDouble < rhsDouble
        default:
            fatalError("Can't compare two different choice values!")
        }
    }
}
