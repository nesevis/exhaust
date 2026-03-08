/// Distribution strategy controlling how tightly generated values cluster around an origin as the generator size grows from 1 to 100.
///
/// Inspired by Hedgehog's `Range` types. The scaling is applied in bit-pattern space by ``Gen/choose(in:scaling:)`` so it works uniformly across all ``BitPatternConvertible`` types.
public enum SizeScaling<Bound: Sendable>: Sendable {
    /// Full range at all sizes. No size interaction.
    case constant

    /// Linear interpolation from lower bound toward upper bound as size grows.
    case linear

    /// Linear interpolation from an explicit origin toward both bounds as size grows.
    case linearFrom(origin: Bound)

    /// Exponential interpolation from lower bound toward upper bound.
    case exponential

    /// Exponential interpolation from an explicit origin toward both bounds.
    /// Tightest at small sizes — ideal for centering on 0 while still reaching the full range at size 100.
    case exponentialFrom(origin: Bound)
}
