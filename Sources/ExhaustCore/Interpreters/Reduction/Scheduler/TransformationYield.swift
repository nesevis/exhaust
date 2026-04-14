//
//  TransformationYield.swift
//  Exhaust
//

// MARK: - Affine Slack

/// Approximation slack for a graph transformation, from the affine monoid Aff_{>=0}.
///
/// For exact reductions (removal, replacement, permutation): (1, 0). For approximate reductions (exchange): (1, beta) where beta is the shortlex distance budget the intermediate may exceed the starting point.
///
/// Composition follows the monoidal product: (alpha, beta) (x) (alpha', beta') = (alpha . alpha', beta + alpha . beta'). Multiplicative factors multiply and additive terms accumulate with upstream scaling (Sepulveda-Jimenez, Def. 8.1).
///
/// The categorical framework defines Aff_{>=0} with real-valued (alpha, beta). For Exhaust's use cases, multiplicative is always 1: reductions are either exact or approximate with unit multiplicative. The full real-valued structure from the paper is available if future operations require non-unity multiplicative factors.
struct AffineSlack: Comparable, Equatable {
    /// Multiplicative factor. Always 1 for current reduction use cases.
    let multiplicative: Int

    /// Additive slack: shortlex distance budget the intermediate may exceed the starting point.
    let additive: Int

    /// Identity element: exact reduction with no slack.
    static let exact = AffineSlack(multiplicative: 1, additive: 0)

    /// Composes two slacks under the monoidal product.
    ///
    /// - Parameter other: The downstream slack to compose with.
    /// - Returns: The composed slack where multiplicative factors multiply and additive terms accumulate with upstream scaling.
    func composed(with other: AffineSlack) -> AffineSlack {
        AffineSlack(
            multiplicative: multiplicative * other.multiplicative,
            additive: additive + multiplicative * other.additive
        )
    }

    /// Lower slack is preferred: lower additive first, then lower multiplicative.
    static func < (lhs: AffineSlack, rhs: AffineSlack) -> Bool {
        if lhs.additive != rhs.additive {
            return lhs.additive < rhs.additive
        }
        return lhs.multiplicative < rhs.multiplicative
    }
}

// MARK: - Transformation Yield

/// Packages structural yield, value yield, approximation slack, and estimated resource cost for a graph transformation.
///
/// Corresponds to G = Aff_{>=0} x W (Sepulveda-Jimenez, Def. 10.1), where the approximation component tracks quality loss and the resource component tracks probe count. Grades compose under the monoidal product law: structural yields sum, value yields take the max, slack composes via ``AffineSlack/composed(with:)``, and costs sum.
///
/// The scheduler orders scopes by grade: structural yield descending, then value yield descending, then slack ascending (exact preferred over approximate), then estimated probes ascending (cheaper preferred at equal yield). The ``Comparable`` conformance encodes "less than" as "higher priority" so that sorting produces a highest-priority-first queue.
struct TransformationYield: Comparable, Equatable {
    /// Sequence positions removed. Zero for minimization, exchange, and permutation.
    let structural: Int

    /// Bound subtree size that reducing this value would structurally unlock. Zero for removal, replacement, exchange, and permutation.
    let value: Int

    /// Approximation slack. Identity (1, 0) for exact reductions.
    let slack: AffineSlack

    /// Expected number of probes the encoder will need.
    let estimatedProbes: Int

    /// Identity element for composition. Composing with identity preserves the other operand unchanged.
    static let identity = TransformationYield(
        structural: 0,
        value: 0,
        slack: .exact,
        estimatedProbes: 0
    )

    /// Composes two yields under the monoidal product.
    ///
    /// Structural yields sum (both steps reduce the sequence independently).
    /// Value yield takes the max (the compound enables the most enabling step's potential). Slack composes via ``AffineSlack/composed(with:)``.
    /// Costs sum (sequential probe budgets are additive).
    ///
    /// - Parameter other: The downstream yield to compose with.
    /// - Returns: The composed yield for the compound transformation.
    func composed(with other: TransformationYield) -> TransformationYield {
        TransformationYield(
            structural: structural + other.structural,
            value: max(value, other.value),
            slack: slack.composed(with: other.slack),
            estimatedProbes: estimatedProbes + other.estimatedProbes
        )
    }

    /// Higher priority is "less than" for sorting into a highest-priority-first queue. Structural yield dominates value yield. Within each tier, higher yield wins. At equal yield, exact reductions are preferred over approximate. At equal yield and slack, lower cost wins.
    static func < (lhs: TransformationYield, rhs: TransformationYield) -> Bool {
        if lhs.structural != rhs.structural {
            return lhs.structural > rhs.structural
        }
        if lhs.value != rhs.value {
            return lhs.value > rhs.value
        }
        if lhs.slack != rhs.slack {
            return lhs.slack < rhs.slack
        }
        return lhs.estimatedProbes < rhs.estimatedProbes
    }
}
