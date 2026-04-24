/// Controls when the online CGS interpreter synthesizes a pick over subranges for `chooseBits` sites.
///
/// The default thresholds are calibrated for `.filter(.choiceGradientSampling)`, where users expect fast generation against typically loose predicates. `#explore` relaxes both thresholds because the user has explicitly asked for steering and is paying tuning cost willingly.
package struct CGSSubdivisionThresholds: Sendable {
    /// The minimum number of values in a `chooseBits` range before subdivision fires. Ranges below this threshold are left as raw `chooseBits` sites.
    package let minimumRangeSize: UInt64

    /// The maximum derivative-context depth at which subdivision fires. Sites deeper than this threshold fall back to static generator weights.
    package let maximumDerivativeDepth: Int

    /// Creates a threshold configuration with explicit values.
    package init(minimumRangeSize: UInt64, maximumDerivativeDepth: Int) {
        self.minimumRangeSize = minimumRangeSize
        self.maximumDerivativeDepth = maximumDerivativeDepth
    }

    /// Default thresholds for `.filter(.choiceGradientSampling)`: range size at least 1000, derivative depth below three.
    package static let `default` = CGSSubdivisionThresholds(
        minimumRangeSize: 1000,
        maximumDerivativeDepth: 3
    )

    /// Relaxed thresholds for `#explore` direction tuning: any range with structural variation, derivative depth below 10.
    package static let relaxed = CGSSubdivisionThresholds(
        minimumRangeSize: 2,
        maximumDerivativeDepth: 10
    )
}
