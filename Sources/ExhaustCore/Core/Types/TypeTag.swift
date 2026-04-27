//
//  TypeTag.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/8/2025.
//

/// Identifies the numeric type of a ``ChoiceValue``, used for reconstruction, display, and boundary analysis.
public enum TypeTag: Sendable {
    /// Platform-width unsigned integer (`UInt`).
    case uint
    /// 64-bit unsigned integer.
    case uint64
    /// 32-bit unsigned integer.
    case uint32
    /// 16-bit unsigned integer.
    case uint16
    /// 8-bit unsigned integer.
    case uint8
    /// Platform-width signed integer (`Int`).
    case int
    /// 64-bit signed integer.
    case int64
    /// 32-bit signed integer.
    case int32
    /// 16-bit signed integer.
    case int16
    /// 8-bit signed integer.
    case int8
    /// Double-precision floating point.
    case double
    /// Single-precision floating point.
    case float
    /// Half-precision floating point (ARM64 only).
    case float16
    /// Date steps: the underlying integer represents step indices, where each step is `intervalSeconds` seconds offset from `lowerSeconds`. Used by boundary analysis to compute calendar-meaningful boundary values (month/year boundaries, DST transitions). The `timeZoneID` limits DST boundary values to a single timezone.
    case date(lowerSeconds: Int64, intervalSeconds: Int64, timeZoneID: String)
    /// Raw bit storage used by composite generators (UUID, Int128, UInt128). Boundary analysis produces only all-low / all-high values.
    case bits
    /// Unicode scalar index: a contiguous integer index into a ``ScalarRangeSet``. Stored as `UInt32`. The bit pattern is an index, not a Unicode code point. The associated boundary indices are pre-computed by ``ScalarRangeSet`` during construction and used by ``BoundaryDomainAnalysis`` for coverage analysis.
    case character(boundaryIndices: [UInt64])

    /// Creates a type tag by matching the metatype of the given value against known numeric types.
    public init<T>(type: T) {
        self = switch type {
        case is Double.Type:
            .double
        case is Int.Type:
            .int
        case is UInt.Type:
            .uint
        // More specific, less likely to be used
        case is Float.Type:
            .float
        case is Int64.Type:
            .int64
        case is Int32.Type:
            .int32
        case is Int16.Type:
            .int16
        case is Int8.Type:
            .int8
        case is UInt64.Type:
            .uint64
        case is UInt32.Type:
            .uint32
        case is UInt16.Type:
            .uint16
        case is UInt8.Type:
            .uint8
        default:
            fatalError("Unexpected type passed to \(#function): \(T.self)")
        }
    }
}

package extension TypeTag {
    /// Whether this tag represents a signed integer type.
    var isSigned: Bool {
        switch self {
        case .int, .int8, .int16, .int32, .int64:
            true
        default:
            false
        }
    }

    /// Whether this tag represents a floating-point type.
    var isFloatingPoint: Bool {
        switch self {
        case .double, .float, .float16:
            true
        default:
            false
        }
    }

    /// The full bit-pattern range reachable by the underlying type.
    ///
    /// Equivalent to `Underlying.bitPatternRange` — bridges the static protocol requirement through this tag's type identity. Used by encoders to detect when a value's declared domain equals the natural type width, enabling modular bit-pattern arithmetic without encoder-level range validation.
    var bitPatternRange: ClosedRange<UInt64> {
        type(of: makeConvertible(bitPattern64: 0)).bitPatternRange
    }

    /// The bit pattern of this tag's semantically simplest value under the order-preserving encoding.
    ///
    /// Unsigned integers, raw bits, and character indices are encoded identically to their natural representation, so zero is `0`. Signed integers XOR the sign bit, mapping `0` to the midpoint of the bit-pattern range (for example, `Int16(0).bitPattern64 == 0x8000`). Floating-point types apply a Hedgehog-style sign-preserving transform that also maps positive zero to the midpoint of the bit-pattern range.
    ///
    /// This is the fast-path equivalent of ``ChoiceValue/semanticSimplest``.`bitPattern64` and is used by ``Gen/scaledRange(_:scaling:size:)`` to anchor bare `.linear` and `.exponential` distributions without allocating a ``ChoiceValue``.
    @inline(__always)
    var simplestBitPattern: UInt64 {
        switch self {
        case .uint, .uint64, .uint32, .uint16, .uint8, .bits, .character:
            0
        case .int8:
            1 << 7
        case .int16:
            1 << 15
        case .int32, .float:
            1 << 31
        case .float16:
            1 << 15
        case .int, .int64, .date, .double:
            1 << 63
        }
    }

    /// Creates a ``ChoiceValue`` by narrowing a `Double` to this tag's floating-point type.
    ///
    /// Returns `nil` if the tag is not a floating-point type, or if the narrowed result is non-finite and `allowNonFinite` is `false`.
    func floatingChoice(from value: Double, allowNonFinite: Bool = false) -> ChoiceValue? {
        switch self {
        case .double:
            guard allowNonFinite || value.isFinite else { return nil }
            return ChoiceValue(value, tag: .double)
        case .float:
            let narrowed = Float(value)
            guard allowNonFinite || narrowed.isFinite else { return nil }
            return ChoiceValue(narrowed, tag: .float)
        case .float16:
            let encoded = Float16Emulation.encodedBitPattern(from: value)
            let reconstructed = Float16Emulation.doubleValue(fromEncoded: encoded)
            guard allowNonFinite || reconstructed.isFinite else { return nil }
            return .floating(reconstructed, encoded, .float16)
        default:
            return nil
        }
    }

    /// Decodes an order-preserving bit pattern to its numeric `Double` value for this tag's floating-point type.
    ///
    /// For `.float` and `.float16`, narrows through the intermediate type so the encoding round-trips correctly.
    func numericDoubleValue(forBitPattern bitPattern: UInt64) -> Double {
        switch self {
        case .double: Double(bitPattern64: bitPattern)
        case .float: Double(Float(bitPattern64: bitPattern))
        case .float16: Float16Emulation.doubleValue(fromEncoded: bitPattern)
        default: fatalError("numericDoubleValue requires a floating-point tag, got \(self)")
        }
    }

    /// Encodes a `Double` value as an order-preserving bit pattern for this tag's floating-point type.
    ///
    /// For `.float` and `.float16`, narrows to the intermediate type first so precision matches the tag's width.
    func floatingBitPattern(from value: Double) -> UInt64 {
        switch self {
        case .double: value.bitPattern64
        case .float: Float(value).bitPattern64
        case .float16: Float16Emulation.encodedBitPattern(from: value)
        default: fatalError("floatingBitPattern requires a floating-point tag, got \(self)")
        }
    }

    /// Remaps a uniformly-drawn bit pattern into a numerically-uniform floating-point bit pattern within the given range.
    ///
    /// `chooseBits` draws a uniform `UInt64` in `[range.lowerBound, range.upperBound]`. For floating-point types, uniform bit patterns concentrate samples near zero because IEEE 754 has exponentially more representable values near zero than far from it. This method redistributes the drawn bits so the resulting float is uniformly distributed across the *numeric* range instead.
    ///
    /// The drawn value's position within the bit-pattern range is used as a linear interpolation fraction, which is then applied to the numeric range and encoded back to a bit pattern.
    ///
    /// Inspired by Hypothesis's `make_float_clamper` (`hypothesis-python/src/hypothesis/internal/floats.py`), which uses `min_value + range_size * (mantissa / mantissa_mask)` to achieve uniform numeric coverage within bounded float ranges.
    ///
    /// - Parameters:
    ///   - rawBits: A uniformly-drawn `UInt64` within `range`.
    ///   - range: The order-preserving bit-pattern range from the `chooseBits` operation.
    /// - Returns: A bit pattern whose decoded float is uniformly distributed in `[numericLower, numericUpper]`.
    func linearlyDistributed(rawBits: UInt64, in range: ClosedRange<UInt64>) -> UInt64 {
        let width = range.upperBound &- range.lowerBound
        guard width > 0 else { return rawBits }
        var lower = numericDoubleValue(forBitPattern: range.lowerBound)
        var upper = numericDoubleValue(forBitPattern: range.upperBound)
        if lower.isNaN || lower.isInfinite { lower = -Double.greatestFiniteMagnitude }
        if upper.isNaN || upper.isInfinite { upper = Double.greatestFiniteMagnitude }
        // When the numeric endpoints are equal (for example ±0.0), the lerp collapses to a single point. Fall back to raw bits so bit-pattern-level distinctions are preserved.
        guard lower != upper else { return rawBits }
        let fraction = Double(rawBits &- range.lowerBound) / Double(width)
        let value = lower * (1.0 - fraction) + upper * fraction
        return floatingBitPattern(from: value)
    }

    /// Clamps a bit pattern into `[min, max]`, except for floating-point NaN/infinity which pass through unclamped so the reducer can see and reduce non-finite boundary values.
    @inline(__always)
    func clampBits(_ bitPattern: UInt64, min: UInt64, max: UInt64) -> UInt64 {
        let clamped = Swift.min(Swift.max(bitPattern, min), max)
        if clamped != bitPattern, isFloatingPoint { return bitPattern }
        return clamped
    }

    /// Creates a ``BitPatternConvertible`` value from a raw bit pattern using this tag's type.
    func makeConvertible(bitPattern64: UInt64) -> any BitPatternConvertible {
        switch self {
        case .uint: UInt(bitPattern64: bitPattern64)
        case .uint64: UInt64(bitPattern64: bitPattern64)
        case .uint32: UInt32(bitPattern64: bitPattern64)
        case .uint16: UInt16(bitPattern64: bitPattern64)
        case .uint8: UInt8(bitPattern64: bitPattern64)
        case .int: Int(bitPattern64: bitPattern64)
        case .int64: Int64(bitPattern64: bitPattern64)
        case .int32: Int32(bitPattern64: bitPattern64)
        case .int16: Int16(bitPattern64: bitPattern64)
        case .int8: Int8(bitPattern64: bitPattern64)
        case .double: Double(bitPattern64: bitPattern64)
        case .float: Float(bitPattern64: bitPattern64)
        #if arch(arm64) || arch(arm64_32)
            case .float16: Float16(bitPattern64: bitPattern64)
        #else
            case .float16: Float(Float16Emulation.doubleValue(fromEncoded: bitPattern64))
        #endif
        case .date: Int64(bitPattern64: bitPattern64)
        case .bits: UInt64(bitPattern64: bitPattern64)
        case .character: UInt32(bitPattern64: bitPattern64)
        }
    }
}

extension TypeTag: Equatable {
    public static func == (lhs: TypeTag, rhs: TypeTag) -> Bool {
        switch (lhs, rhs) {
        case (.uint, .uint), (.uint64, .uint64), (.uint32, .uint32),
            (.uint16, .uint16), (.uint8, .uint8),
            (.int, .int), (.int64, .int64), (.int32, .int32),
            (.int16, .int16), (.int8, .int8),
            (.double, .double), (.float, .float), (.float16, .float16),
            (.bits, .bits), (.character, .character):
            true
        case let (.date(lhsLower, lhsInterval, lhsTZ), .date(rhsLower, rhsInterval, rhsTZ)):
            lhsLower == rhsLower && lhsInterval == rhsInterval && lhsTZ == rhsTZ
        default:
            false
        }
    }
}

extension TypeTag: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .uint: hasher.combine(0)
        case .uint64: hasher.combine(1)
        case .uint32: hasher.combine(2)
        case .uint16: hasher.combine(3)
        case .uint8: hasher.combine(4)
        case .int: hasher.combine(5)
        case .int64: hasher.combine(6)
        case .int32: hasher.combine(7)
        case .int16: hasher.combine(8)
        case .int8: hasher.combine(9)
        case .double: hasher.combine(10)
        case .float: hasher.combine(11)
        case .float16: hasher.combine(12)
        case let .date(lower, interval, tzID):
            hasher.combine(13)
            hasher.combine(lower)
            hasher.combine(interval)
            hasher.combine(tzID)
        case .bits: hasher.combine(14)
        case .character: hasher.combine(15)
        }
    }
}

extension TypeTag: CustomStringConvertible {
    public var description: String {
        switch self {
        case .uint: "UInt"
        case .uint64: "UInt64"
        case .uint32: "UInt32"
        case .uint16: "UInt16"
        case .uint8: "UInt8"
        case .int: "Int"
        case .int64: "Int64"
        case .int32: "Int32"
        case .int16: "Int16"
        case .int8: "Int8"
        case .double: "Double"
        case .float: "Float"
        case .float16: "Float16"
        case .date: "Date"
        case .bits: "Bits"
        case .character: "Character"
        }
    }
}

package extension TypeTag {
    /// Whether this tag represents a character index type.
    var isCharacter: Bool {
        if case .character = self { return true }
        return false
    }
}
