/// Selects numeric payload domains independently of a derived generator's structural limits.
///
/// ```swift
/// @Exhaustable(stateSpace: .small)
/// struct Position { let offset: Int }
/// ```
///
/// Bounded presets limit fixed-width integers and binary floating-point magnitudes to 10, 100, or 10,000 at full size. Their bounds grow linearly from zero with size; unsigned bounds start at zero, and bounds are clipped to the numeric type's range. These presets do not limit the total number of possible outputs, container lengths, enum cases, strings, or other Foundation values. Explicit payload overrides keep their own domains.
///
/// An unconfigured root uses `.full`. Nested annotations cap the inherited preset, so a nested `.full` does not widen a parent's `.small`. An explicit factory argument replaces the root annotation, but nested annotations still cap their occurrences. Reflection rejects numeric values outside the selected domain.
public enum GeneratorStateSpace: String, CaseIterable, Sendable {
    /// Limits numeric magnitudes to 10 at full size, encouraging repeated values.
    case tiny
    /// Limits numeric magnitudes to 100 at full size, matching QuickCheck-style integer sizing.
    case small
    /// Limits numeric magnitudes to 10,000 at full size without using the machine-wide domain.
    case medium
    /// Preserves each built-in generator's existing domain and scaling policy.
    case full

    /// Supplies the full-size magnitude without importing generator infrastructure into an application module.
    package var numericMagnitude: Int? {
        switch self {
            case .tiny:
                10
            case .small:
                100
            case .medium:
                10000
            case .full:
                nil
        }
    }

    /// Prevents a nested annotation from widening the domain selected by its parent.
    package func limited(by ceiling: Self) -> Self {
        (numericMagnitude ?? Int.max) <= (ceiling.numericMagnitude ?? Int.max) ? self : ceiling
    }
}
