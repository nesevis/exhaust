//
//  TypeTag.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/8/2025.
//

/// Identifies the numeric type of a ``ChoiceValue``, used for reconstruction, display, and problematic-value analysis.
///
/// TypeTag is a pure discriminator — it carries no per-generator metadata. Analysis-relevant payloads (date parameters, character problematic indices) live in ``TypeTagPayload``, stored alongside the tag in ``ChoiceMetadata`` on ChoiceTree nodes. This keeps TypeTag at one byte so that ``ChoiceValue`` and ``ChoiceSequenceValue`` stay compact in the flat ``ChoiceSequence`` that the reducer copies, hashes, and compares thousands of times per reduction.
@usableFromInline
package enum TypeTag: UInt8, Sendable, Hashable {
    /// Platform-width unsigned integer (`UInt`).
    case uint = 0
    /// 64-bit unsigned integer.
    case uint64 = 1
    /// 32-bit unsigned integer.
    case uint32 = 2
    /// 16-bit unsigned integer.
    case uint16 = 3
    /// 8-bit unsigned integer.
    case uint8 = 4
    /// Platform-width signed integer (`Int`).
    case int = 5
    /// 64-bit signed integer.
    case int64 = 6
    /// 32-bit signed integer.
    case int32 = 7
    /// 16-bit signed integer.
    case int16 = 8
    /// 8-bit signed integer.
    case int8 = 9
    /// Double-precision floating point.
    case double = 10
    /// Single-precision floating point.
    case float = 11
    /// Half-precision floating point (ARM64 only).
    case float16 = 12
    /// Date steps: the underlying integer represents step indices. The per-generator parameters (interval, lower bound, timezone) are stored in ``TypeTagPayload/date(lowerSeconds:intervalSeconds:timeZoneID:)`` on the ``ChoiceMetadata``.
    case date = 13
    /// Raw bit storage used by composite generators (UUID, Int128, UInt128). Problematic-value analysis produces only all-low / all-high values.
    case bits = 14
    /// Unicode scalar index: a contiguous integer index into a ``ScalarRangeSet``. The pre-computed problematic indices are stored in ``TypeTagPayload/character(problematicIndices:)`` on the ``ChoiceMetadata``.
    case character = 15
    /// Recursion depth control: selects which pre-built layer of a recursive generator to unfold. Excluded from value search because reducing it collapses recursive layers, destroying structural context (branch pivots, self-similar replacements) in the bound subtree. Structural operations (self-similar replacement, descendant promotion) handle depth reduction while preserving structural integrity.
    case depthControl = 16
    /// Tags a structural scheduling decision that coverage analysis should skip but the reducer should minimize normally. Used for lane assignment in concurrent contract testing — the covering array covers command types without the combinatorial cost of lane combinations, while the reducer drives markers toward 0 (prefix) to discover minimal concurrency.
    case laneControl = 17
}

/// Per-generator metadata for ``TypeTag`` cases that carry analysis-relevant payloads.
///
/// Stored in ``ChoiceMetadata`` on ``ChoiceTree`` nodes (heap-allocated, no stride impact on the flat ``ChoiceSequence``). Consumed only by ``ProblematicValues`` during one-time coverage analysis.
@usableFromInline
package enum TypeTagPayload: Hashable, Sendable {
    /// Date step parameters. Used by ``ProblematicValues`` to compute calendar-meaningful problematic values (month/year boundaries, DST transitions).
    case date(lowerSeconds: Int64, intervalSeconds: Int64, timeZoneID: String)
    /// Pre-computed problematic character indices. Corresponds to ``ProblematicValues/interestingCharacterScalars`` in flat array index space, clamped to the valid range during construction.
    case character(problematicIndices: [UInt64])
}

package extension TypeTag {
    var discriminator: Int {
        Int(rawValue)
    }

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

    /// The greatest finite magnitude of this tag's floating-point type, expressed as a `Double`.
    ///
    /// Used by ``linearlyDistributed(rawBits:in:)`` and floating-point scaling to clamp NaN/infinity fallback endpoints to the tag's own representable range, not `Double`'s. Without this, a lerp endpoint of `±1.8e308` overflows `Float`'s maximum (`3.4e38`) and `Float16`'s maximum (`65504`), producing `±infinity` for most samples.
    var greatestFiniteDoubleMagnitude: Double {
        switch self {
            case .double:
                Double.greatestFiniteMagnitude
            case .float:
                Double(Float.greatestFiniteMagnitude)
            case .float16:
                65504.0
            default:
                fatalError("greatestFiniteDoubleMagnitude requires a floating-point tag, got \(self)")
        }
    }

    /// Whether this tag represents a character index type.
    var isCharacter: Bool {
        self == .character
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
            case .uint, .uint64, .uint32, .uint16, .uint8, .bits, .character, .depthControl, .laneControl:
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
                return ChoiceValue(encoded, tag: .float16)
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
    /// ``chooseBits`` draws a uniform ``UInt64`` in `[range.lowerBound, range.upperBound]`. For floating-point types, uniform bit patterns concentrate samples near zero because IEEE 754 has exponentially more representable values near zero than far from it. This method redistributes the drawn bits so the resulting float is uniformly distributed across the *numeric* range instead.
    ///
    /// The drawn value's position within the bit-pattern range is used as a linear interpolation fraction, which is then applied to the numeric range and encoded back to a bit pattern.
    ///
    /// Inspired by Hypothesis's `make_float_clamper` (`hypothesis-python/src/hypothesis/internal/floats.py`), which uses `min_value + range_size * (mantissa / mantissa_mask)` to achieve uniform numeric coverage within bounded float ranges.
    ///
    /// - Parameters:
    ///   - rawBits: A uniformly-drawn ``UInt64`` within `range`.
    ///   - range: The order-preserving bit-pattern range from the ``chooseBits`` operation.
    /// - Returns: A bit pattern whose decoded float is uniformly distributed in `[numericLower, numericUpper]`.
    func linearlyDistributed(rawBits: UInt64, in range: ClosedRange<UInt64>) -> UInt64 {
        let width = range.upperBound &- range.lowerBound
        guard width > 0 else { return rawBits }
        var lower = numericDoubleValue(forBitPattern: range.lowerBound)
        var upper = numericDoubleValue(forBitPattern: range.upperBound)
        if lower.isNaN || lower.isInfinite {
            lower = -greatestFiniteDoubleMagnitude
        }
        if upper.isNaN || upper.isInfinite {
            upper = greatestFiniteDoubleMagnitude
        }
        // When the numeric endpoints are equal (for example ±0.0), the lerp collapses to a single point. Fall back to raw bits so bit-pattern-level distinctions are preserved.
        guard lower != upper else { return rawBits }
        let fraction = Double(rawBits &- range.lowerBound) / Double(width)
        let value = lower * (1.0 - fraction) + upper * fraction
        return floatingBitPattern(from: value)
    }

    /// Clamps a bit pattern into `[min, max]`, except for floating-point NaN/infinity which pass through unclamped so the reducer can see and reduce non-finite problematic values.
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
                case .float16:
                    if #available(macOS 11, iOS 14, tvOS 14, watchOS 7, *) {
                        Float16(bitPattern64: bitPattern64)
                    } else {
                        Float(Float16Emulation.doubleValue(fromEncoded: bitPattern64))
                    }
            #else
                case .float16: Float(Float16Emulation.doubleValue(fromEncoded: bitPattern64))
            #endif
            case .date: Int64(bitPattern64: bitPattern64)
            case .bits: UInt64(bitPattern64: bitPattern64)
            case .character: UInt32(bitPattern64: bitPattern64)
            case .depthControl, .laneControl: UInt64(bitPattern64: bitPattern64)
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
            case .depthControl: "DepthControl"
            case .laneControl: "Control"
        }
    }
}
