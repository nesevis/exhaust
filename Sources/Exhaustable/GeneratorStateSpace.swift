/// Selects default payload domains independently of a derived generator's structural limits.
///
/// ```swift
/// @Exhaustable(stateSpace: .small)
/// struct Position { let offset: Int }
/// ```
///
/// Bounded state spaces limit fixed-width integers and binary floating-point magnitudes to 10, 100, or 10,000 at full size. They also limit automatically derived array lengths, set and dictionary cardinalities, string lengths, and `Data` lengths to 5, 10, or 20. Numeric bounds, sequence lengths, and date ranges grow with size; unsigned bounds start at zero, and numeric bounds are clipped to the destination type's range. `.tiny` and `.small` favor collisions by limiting `Date` to 21 or 201 daily values centered on January 1, 2026 UTC at full size. `.medium` leaves the default `Date` domain unchanged because its width does not increase generation or reflection work. Explicit payload overrides keep their own domains.
///
/// An unconfigured root uses `.full`, preserving each built-in generator's existing domain, including its default sequence maximum of 100 and `Date.distantPast...Date.distantFuture` at one-minute resolution. Nested annotations cap the inherited state space, so a nested `.full` does not widen a parent's `.small`. An explicit factory argument replaces the root annotation, but nested annotations still cap their occurrences. Reflection rejects numeric values and sequence lengths outside the selected size-scaled domain. The underlying date leaf retains its documented behavior of rounding to the preceding grid value and clamping to the selected range; enclosing derived constructors still require the reflected replay to reproduce their complete value.
public enum GeneratorStateSpace: String, CaseIterable, Sendable {
    /// Limits numeric magnitudes to 10, default sequence lengths to 5, and dates to 21 daily values centered on January 1, 2026 UTC, encouraging small, repeated values.
    case tiny
    /// Limits numeric magnitudes to 100, default sequence lengths to 10, and dates to 201 daily values centered on January 1, 2026 UTC.
    case small
    /// Limits numeric magnitudes to 10,000 and default sequence lengths to 20 for lower processing costs while preserving the full default date domain.
    case medium
    /// Preserves each built-in generator's existing domain and scaling policy, including default sequence lengths up to 100.
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

    /// Supplies the full-size maximum for automatically derived sequence and collection counts; `nil` preserves the built-in default.
    package var defaultSequenceLengthMaximum: Int? {
        switch self {
            case .tiny:
                5
            case .small:
                10
            case .medium:
                20
            case .full:
                nil
        }
    }

    /// Supplies the radius of the daily default `Date` domain around January 1, 2026; `nil` preserves the built-in default.
    package var defaultDateDayRadius: Int? {
        switch self {
            case .tiny:
                10
            case .small:
                100
            case .medium, .full:
                nil
        }
    }

    /// Prevents a nested annotation from widening the domain selected by its parent.
    package func limited(by ceiling: Self) -> Self {
        (numericMagnitude ?? Int.max) <= (ceiling.numericMagnitude ?? Int.max) ? self : ceiling
    }
}
