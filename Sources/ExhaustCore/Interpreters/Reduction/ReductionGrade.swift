/// Qualitative approximation class for a reduction morphism.
///
/// Captures the distinctions the scheduler uses for phase ordering, V-cycle structure, and the constraint that speculative encoders must run last. The monoidal product degenerates to a lattice join.
///
/// The paper's grade monoid uses `(alpha, beta) in Aff_>=0` for quantitative approximation tracking. In practice, beta (additive slack from re-derivation) is not concretely computable before the decode call, so a qualitative enum suffices.
public enum ApproximationClass: Int, Comparable, Sendable {
    /// No regression possible. The decoder reproduces the candidate exactly.
    case exact = 0

    /// Re-derivation may shift the result, but the shortlex guard rejects any regression.
    case bounded = 1

    /// The intermediate state may be shortlex-larger than the input. Phase 5 only.
    case speculative = 2

    public static func < (lhs: ApproximationClass, rhs: ApproximationClass) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Lattice join: the composed approximation is the worst of the two.
    public func composed(with other: ApproximationClass) -> ApproximationClass {
        max(self, other)
    }
}

/// The grade of a reduction morphism: approximation class and resource bound.
///
/// The resource bound (`maxMaterializations`) is concrete and computable. The approximation class is qualitative — it determines phase ordering and V-cycle structure, not quantitative budget decisions.
public struct ReductionGrade: Sendable {
    public let approximation: ApproximationClass
    /// Maximum materializations this encoder or morphism will consume.
    public let maxMaterializations: Int

    public init(approximation: ApproximationClass, maxMaterializations: Int) {
        self.approximation = approximation
        self.maxMaterializations = maxMaterializations
    }

    /// Monoidal identity: adds nothing under the additive resource monoid.
    public static let exact = ReductionGrade(approximation: .exact, maxMaterializations: 0)

    public var isExact: Bool { approximation == .exact }

    /// Composes two grades in a pipeline. Approximation is lattice join, resources are additive.
    public func composed(with other: ReductionGrade) -> ReductionGrade {
        ReductionGrade(
            approximation: approximation.composed(with: other.approximation),
            maxMaterializations: maxMaterializations + other.maxMaterializations
        )
    }

    /// Composes an encoder grade with a decoder's approximation class to produce the morphism grade.
    public func composed(withDecoder decoder: ApproximationClass) -> ReductionGrade {
        ReductionGrade(
            approximation: approximation.composed(with: decoder),
            maxMaterializations: maxMaterializations
        )
    }
}
