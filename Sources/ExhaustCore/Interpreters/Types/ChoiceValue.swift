//
//  ChoiceValue.swift
//  Exhaust
//
//  Created by Chris Kolbu on 20/7/2025.
//

/// A single primitive value in the choice tree, tagged with its numeric type.
///
/// Stores only the raw `UInt64` bit pattern and a ``TypeTag``. Decoded values (signed integers, floating-point numbers) are computed on demand from these two fields, trading a per-access decode (single-instruction bitwise reinterpretation) for smaller size and branch-free field access.
@usableFromInline
package struct ChoiceValue: Comparable, Hashable, Sendable {
    /// All numeric types are stored in this single `UInt64` regardless of original width. Signed integers use sign-bit XOR for order-preserving shortlex reduction; floats use a Hedgehog-style sign-preserving transform. Decoding is controlled by ``tag``.
    package let bitPattern64: UInt64
    /// Controls how ``bitPattern64`` is decoded (signed vs unsigned vs float), which reduction strategies apply (shortlex for integers, mantissa-first for floats), and what the semantically simplest value is (zero for all types, but at different bit patterns).
    package let tag: TypeTag

    /// Creates a choice value from a raw bit pattern and type tag.
    package init(_ bitPattern: UInt64, tag: TypeTag) {
        bitPattern64 = bitPattern
        self.tag = tag
    }

    /// Creates a choice value from a ``BitPatternConvertible`` value and its type tag.
    package init(_ value: any BitPatternConvertible, tag: TypeTag) {
        bitPattern64 = value.bitPattern64
        self.tag = tag
    }

    // MARK: - Decoded Value Accessors

    /// The decoded signed integer value. Only valid when ``tag`` is a signed integer type.
    package var decodedSignedValue: Int64 {
        switch tag {
        case .int:
            Int64(Int(bitPattern64: bitPattern64))
        case .int64, .date:
            Int64(bitPattern64: bitPattern64)
        case .int32:
            Int64(Int32(bitPattern64: bitPattern64))
        case .int16:
            Int64(Int16(bitPattern64: bitPattern64))
        case .int8:
            Int64(Int8(bitPattern64: bitPattern64))
        default:
            0
        }
    }

    /// The decoded floating-point value as `Double`. Only valid when ``tag`` is a floating-point type.
    package var decodedDoubleValue: Double {
        switch tag {
        case .double:
            Double(bitPattern64: bitPattern64)
        case .float:
            Double(Float(bitPattern64: bitPattern64))
        case .float16:
            Float16Emulation.doubleValue(fromEncoded: bitPattern64)
        default:
            0.0
        }
    }

    // MARK: - Semantic Properties

    /// The semantically simplest value for a human reader: zero for all numeric types.
    package var semanticSimplest: ChoiceValue {
        ChoiceValue(tag.simplestBitPattern, tag: tag)
    }

    /// Returns whether this value's bit pattern falls within the given range.
    @inline(__always)
    func fits(in range: ClosedRange<UInt64>?) -> Bool {
        guard let range else { return true }
        return range.contains(bitPattern64)
    }

    /// Formats a bit-pattern range into a human-readable string using this value's type tag.
    func displayRange(_ range: ClosedRange<UInt64>) -> String {
        if tag.isSigned || tag.isFloatingPoint {
            let lower = tag.makeConvertible(bitPattern64: range.lowerBound)
            let upper = tag.makeConvertible(bitPattern64: range.upperBound)
            return "\(lower)...\(upper)"
        }
        return range.description
    }

    /// Reconstructs the original ``BitPatternConvertible`` value from this choice's bit pattern and type tag.
    package var convertible: any BitPatternConvertible {
        tag.makeConvertible(bitPattern64: bitPattern64)
    }

    // MARK: - Comparable

    @usableFromInline
    package static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.tag.isFloatingPoint {
            return lhs.decodedDoubleValue < rhs.decodedDoubleValue
        } else if lhs.tag.isSigned {
            return lhs.decodedSignedValue < rhs.decodedSignedValue
        } else {
            return lhs.bitPattern64 < rhs.bitPattern64
        }
    }
}
