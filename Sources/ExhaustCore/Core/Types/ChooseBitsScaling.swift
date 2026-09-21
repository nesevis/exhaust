//
//  ChooseBitsScaling.swift
//  Exhaust
//

/// Size-scaling strategy attached to a ``ReflectiveOperation/chooseBits(min:max:tag:isRangeExplicit:scaling:)`` operation.
///
/// Sampling interpreters consult the current generation size when a chooseBits carries a non-nil scaling, narrowing the effective sampling range relative to the declared `(min, max)` range. Reflection enforces that effective range inside an explicit ``ReflectiveOperation/resize(newSize:next:)`` scope and otherwise uses the full size-100 range. Analysis and tree metadata retain the declared range so reduction can explore beyond the generated size.
///
/// ``Kind`` says how the effective range grows with size; ``samplingBounds`` says where it may reach. Keeping them apart is what lets the range computation dispatch on every kind, rather than special-casing a bounded variant before it.
///
/// - Note: A `nil` scaling on ``ReflectiveOperation/chooseBits(min:max:tag:isRangeExplicit:scaling:)`` samples the full declared range uniformly at every size. A ``Kind/constant`` scaling represents the same distribution when ``samplingBounds`` narrows generation to part of the declared range.
@usableFromInline
package struct ChooseBitsScaling: Sendable, Hashable {
    /// How the effective sampling range grows from its origin as size increases.
    @usableFromInline
    package enum Kind: Sendable, Hashable {
        /// Samples the complete sampling range at every size.
        case constant

        /// Linear interpolation from the origin toward both bounds as size grows.
        ///
        /// When `originBits` is `nil`, the origin is resolved at sample time to the tag's ``TypeTag/simplestBitPattern`` clamped into the range.
        case linear(originBits: UInt64?)

        /// Exponential interpolation from the origin toward both bounds as size grows.
        ///
        /// When `originBits` is `nil`, the origin is resolved at sample time to the tag's ``TypeTag/simplestBitPattern`` clamped into the range.
        case exponential(originBits: UInt64?)

        /// Pins the sample to the current generation size, clamped into the range.
        ///
        /// Sampling interpreters take the pinned bit pattern without consuming a PRNG draw, so a generator carrying this scaling leaves the seed stream exactly as a raw ``ReflectiveOperation/getSize`` would. The choice still occupies an entry in the ``ChoiceSequence`` with the declared range as its valid range, which is what lets the reducer move the size after generation. Screening analysis and CGS subdivision skip these choices: the value is a context parameter, not a sampled one.
        case size
    }

    /// How the effective range grows with size.
    package let kind: Kind

    /// Bounds the sample stays inside, narrower than the operation's declared range. A `nil` value samples the declared range.
    ///
    /// Only generation reads these. Reflection, analysis, and the reducer see the declared range, so a value beyond these bounds still decomposes and still reduces.
    package let samplingBounds: ClosedRange<UInt64>?

    /// Constant sampling, optionally confined to bounds narrower than the declared range.
    package static func constant(
        samplingWithin samplingBounds: ClosedRange<UInt64>? = nil
    ) -> Self {
        Self(kind: .constant, samplingBounds: samplingBounds)
    }

    /// Linear scaling, optionally confined to bounds narrower than the declared range.
    package static func linear(
        originBits: UInt64?,
        samplingWithin samplingBounds: ClosedRange<UInt64>? = nil
    ) -> Self {
        Self(kind: .linear(originBits: originBits), samplingBounds: samplingBounds)
    }

    /// Exponential scaling, optionally confined to bounds narrower than the declared range.
    package static func exponential(
        originBits: UInt64?,
        samplingWithin samplingBounds: ClosedRange<UInt64>? = nil
    ) -> Self {
        Self(kind: .exponential(originBits: originBits), samplingBounds: samplingBounds)
    }

    /// Pins the sample to the current generation size.
    package static let size = Self(kind: .size, samplingBounds: nil)

    /// Whether this scaling samples the current size rather than a random value.
    var isPinnedToSize: Bool {
        guard case .size = kind else {
            return false
        }
        return true
    }

    /// Intersects `declared` with ``samplingBounds``, giving the range generation draws from.
    ///
    /// - Precondition: The bounds overlap the declared range.
    @inline(__always)
    func samplingRange(within declared: ClosedRange<UInt64>) -> ClosedRange<UInt64> {
        guard let samplingBounds else {
            return declared
        }
        let lower = Swift.max(declared.lowerBound, samplingBounds.lowerBound)
        let upper = Swift.min(declared.upperBound, samplingBounds.upperBound)
        precondition(lower <= upper, "Sampling bounds must overlap the declared range")
        return lower ... upper
    }
}
