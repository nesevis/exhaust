/// Controls the sampled domains of default payloads in an `@Exhaustable`-derived generator.
///
/// Use ``tiny`` or ``small`` for collisions, ``medium`` to cap generated value size, ``full`` for built-in defaults, and ``custom(numericMagnitude:scaling:)`` when no preset has the numeric range a workload needs. Limits apply at size 100 and grow with Exhaust's size parameter unless numeric scaling is constant. Numeric and sequence limits shape generated samples without restricting reflection, so existing values outside them can still be reduced. Date presets retain the domains shown below.
///
/// | Domain | Numeric magnitude | Numeric scaling | Sequence maximum | Dates |
/// | --- | ---: | --- | ---: | --- |
/// | `.tiny` | 10 | Constant | 10 | 21 days centered on January 1, 2026 UTC |
/// | `.small` | 100 | Constant | 10 | 201 days centered on January 1, 2026 UTC |
/// | `.medium` | 10,000 | Linear | 20 | Unchanged |
/// | `.full` | Unchanged | Unchanged | Unchanged | Unchanged |
///
/// Sequence limits apply to arrays, sets, dictionaries, strings, and `Data`. A nested annotation can narrow a bound inherited from its parent but cannot widen one. Each bound combines independently, so a custom numeric domain nested under ``tiny`` keeps the sequence and date limits of ``tiny``.
public struct ExhaustableDomain: Hashable, Sendable {
    /// Favors frequent collisions with the smallest default domains.
    public static let tiny = Self(
        numeric: NumericPolicy(magnitude: 10, scaling: .constant),
        defaultSequenceLengthMaximum: 10,
        defaultDateDayRadius: 10
    )

    /// Favors collisions while retaining more variation than ``tiny``.
    public static let small = Self(
        numeric: NumericPolicy(magnitude: 100, scaling: .constant),
        defaultSequenceLengthMaximum: 10,
        defaultDateDayRadius: 100
    )

    /// Caps expensive defaults without narrowing the default date range.
    public static let medium = Self(
        numeric: NumericPolicy(magnitude: 10000, scaling: .linear),
        defaultSequenceLengthMaximum: 20,
        defaultDateDayRadius: nil
    )

    /// Preserves each built-in generator's default domain.
    public static let full = Self(
        numeric: nil,
        defaultSequenceLengthMaximum: nil,
        defaultDateDayRadius: nil
    )

    /// Creates a numeric domain without changing default sequence or date bounds.
    ///
    /// Use this when a workload needs a numeric magnitude or size distribution that the named presets do not provide. A nested custom domain still retains any tighter sequence and date limits inherited from its parent.
    ///
    /// ```swift
    /// @Exhaustable(.domain(.custom(numericMagnitude: 50, scaling: .constant)))
    /// struct Inventory {
    ///     let quantities: [Int]
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - numericMagnitude: The largest generated absolute signed value and largest generated unsigned value. Must be nonnegative.
    ///   - scaling: How quickly generation exposes the configured numeric range as size grows.
    /// - Returns: A domain that customizes numeric generation and preserves built-in sequence and date defaults.
    public static func custom(
        numericMagnitude: Int,
        scaling: ExhaustableSizeScaling
    ) -> Self {
        precondition(numericMagnitude >= 0, "Numeric magnitude must be nonnegative")
        return Self(
            numeric: NumericPolicy(magnitude: numericMagnitude, scaling: scaling),
            defaultSequenceLengthMaximum: nil,
            defaultDateDayRadius: nil
        )
    }

    /// Pairs the full-size magnitude with its size distribution so neither exists without the other; `nil` preserves each built-in numeric default.
    package struct NumericPolicy: Hashable, Sendable {
        package let magnitude: Int
        package let scaling: ExhaustableSizeScaling
    }

    /// Supplies the numeric policy without importing generator infrastructure into an application module.
    package let numeric: NumericPolicy?

    /// Supplies the full-size maximum for automatically derived sequence and collection counts; `nil` preserves the built-in default.
    package let defaultSequenceLengthMaximum: Int?

    /// Supplies the radius of the daily default `Date` domain around January 1, 2026; `nil` preserves the built-in default.
    package let defaultDateDayRadius: Int?

    private init(
        numeric: NumericPolicy?,
        defaultSequenceLengthMaximum: Int?,
        defaultDateDayRadius: Int?
    ) {
        self.numeric = numeric
        self.defaultSequenceLengthMaximum = defaultSequenceLengthMaximum
        self.defaultDateDayRadius = defaultDateDayRadius
    }

    /// Prevents a nested annotation from widening any sampling bound selected by its parent.
    ///
    /// Each bound combines independently, so the result can differ from both operands. The ceiling's numeric scaling wins when magnitudes tie.
    package func limited(by ceiling: Self) -> Self {
        Self(
            numeric: tighter(ceiling.numeric, numeric, by: \.magnitude),
            defaultSequenceLengthMaximum: tighter(
                ceiling.defaultSequenceLengthMaximum,
                defaultSequenceLengthMaximum,
                by: \.self
            ),
            defaultDateDayRadius: tighter(
                ceiling.defaultDateDayRadius,
                defaultDateDayRadius,
                by: \.self
            )
        )
    }
}

/// Selects how a custom ``ExhaustableDomain`` exposes its numeric magnitude as generation size grows.
///
/// This app-safe counterpart to the generator runtime's `SizeScaling` omits explicit origins because one domain applies across payloads of different numeric types.
public enum ExhaustableSizeScaling: Hashable, Sendable {
    /// Samples the complete configured numeric range at every size.
    ///
    /// Use this for small magnitudes where collisions matter from the first sample.
    case constant

    /// Expands the sampled numeric range proportionally as size grows.
    ///
    /// A magnitude of 10,000 samples within 1,000 of zero at size 10, so small values become rare early in a run.
    case linear

    /// Keeps early samples near zero and reaches the complete numeric range at size 100.
    ///
    /// A magnitude of 10,000 samples within 99 of zero at size 50. Use this when small values and collisions should dominate most of a run.
    case exponential
}

// MARK: - Helpers

/// Selects the smaller of two optional limits, treating `nil` as unbounded and preferring the ceiling on ties.
private func tighter<Limit>(
    _ ceiling: Limit?,
    _ inherited: Limit?,
    by size: KeyPath<Limit, Int>
) -> Limit? {
    guard let ceiling, let inherited else {
        return ceiling ?? inherited
    }
    return switch ceiling[keyPath: size] <= inherited[keyPath: size] {
        case true:
            ceiling
        case false:
            inherited
    }
}
