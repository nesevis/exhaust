/// Distribution strategy controlling how tightly generated values cluster around an origin as the generator size grows from 1 to 100.
///
/// Inspired by Hedgehog's `Range` types. The scaling is applied in bit-pattern space by ``Gen/choose(in:scaling:)`` so it works uniformly across all ``BitPatternConvertible`` types.
///
/// ## Choosing a scaling
///
/// - Use ``exponential`` (the default for all numeric types) when the range spans the full width of a numeric type. Its `pow(distance + 1, fraction) - 1` shape keeps the effective range tiny at small sizes and only unfolds toward the extremes as size grows, so single-digit values are reached naturally.
/// - Use ``linear`` when the range is narrow enough that one percent of its width is a meaningful small number — for example `Int` in `0...1000`, `Int8`, or an explicit character range. On full-width numeric types (`Int`, `Double`, `UInt64`), one percent of the range is already astronomical, so linear effectively skips the small-value regime.
/// - Use ``constant`` to disable size ramping entirely and sample the full range uniformly from the first run.
public enum SizeScaling<Bound: Sendable>: Sendable {
    /// Full range at all sizes. No size interaction.
    case constant

    /// Linear interpolation around the type's semantically simplest value as size grows, clamped to the range. For signed and floating-point types this anchors at zero when the range contains zero; for unsigned types it anchors at the lower bound.
    ///
    /// - Important: Linear growth is proportional to the width of the declared range. On full-width numeric types (`Int`, `Double`, `UInt64`), one percent of the range is already ~10¹⁷, so linear never visits small values. Reach for ``exponential`` on wide ranges; linear is best suited to narrow ranges such as `Int8`, explicit bounded ranges (for example `.int(in: 0...1000, scaling: .linear)`), or character code point ranges.
    case linear

    /// Linear interpolation from an explicit origin toward both bounds as size grows.
    case linearFrom(origin: Bound)

    /// Exponential interpolation around the type's semantically simplest value, clamped to the range. For signed and floating-point types this anchors at zero when the range contains zero; for unsigned types it anchors at the lower bound. Tightest at small sizes — ideal for exercising values near zero while still reaching the full range at size 100.
    ///
    /// - Note: Preferred over ``linear`` for full-width numeric ranges. The distance grows as `pow(distance + 1, size/100) - 1`, which keeps the effective range close to the origin at small sizes and only opens up near the extremes as size approaches 100.
    case exponential

    /// Exponential interpolation from an explicit origin toward both bounds.
    case exponentialFrom(origin: Bound)
}

package extension SizeScaling where Bound: BitPatternConvertible {
    /// Erases this typed scaling into the type-erased ``ChooseBitsScaling`` stored on ``ReflectiveOperation/chooseBits(min:max:tag:isRangeExplicit:scaling:)``.
    var erased: ChooseBitsScaling? {
        switch self {
        case .constant: nil
        case .linear: .linear(originBits: nil)
        case let .linearFrom(origin): .linear(originBits: origin.bitPattern64)
        case .exponential: .exponential(originBits: nil)
        case let .exponentialFrom(origin): .exponential(originBits: origin.bitPattern64)
        }
    }
}
