/// Controls the sampled domains of default payloads in an `@Exhaustable`-derived generator.
///
/// Use `.tiny` or `.small` for collisions, `.medium` to cap generated value size, and `.full` for built-in defaults. Limits apply at size 100 and grow with Exhaust's size parameter. Numeric and sequence limits shape generated samples without restricting reflection, so existing values outside them can still be reduced. Date presets retain the domains shown below.
///
/// | Domain | Numeric magnitude | Sequence maximum | Dates |
/// | --- | ---: | ---: | --- |
/// | `.tiny` | 10 | 10 | 21 days centered on January 1, 2026 UTC |
/// | `.small` | 100 | 10 | 201 days centered on January 1, 2026 UTC |
/// | `.medium` | 10,000 | 20 | Unchanged |
/// | `.full` | Unchanged | Unchanged | Unchanged |
///
/// Sequence limits apply to arrays, sets, dictionaries, strings, and `Data`. Nested annotations can narrow an inherited domain; explicit payload overrides keep their own domains. Presets compare in declaration order, from narrowest to widest, independently of any individual domain limit.
public enum ExhaustableDomain: CaseIterable, Comparable, Sendable {
    /// Favors frequent collisions with the smallest default domains.
    case tiny
    /// Favors collisions while retaining more variation than `.tiny`.
    case small
    /// Caps expensive defaults without narrowing the default date range.
    case medium
    /// Preserves each built-in generator's default domain.
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
                10
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

    /// Prevents a nested annotation from widening the sampling policy selected by its parent.
    package func limited(by ceiling: Self) -> Self {
        min(self, ceiling)
    }
}
