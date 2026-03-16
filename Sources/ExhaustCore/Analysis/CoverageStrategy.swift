// Coverage strategy protocol and phase ordering for structured coverage dispatch.
//
// Mirrors the SequenceEncoderBase / ReductionPhase pattern from the reducer:
// coverage strategies are protocol conformers ordered by guarantee strength,
// and CoverageRunner iterates them strongest-first until one fits the budget.

/// Coverage guarantee level, ordered by strength (strongest first).
///
/// Mirrors ``ReductionPhase`` from the reducer. Exhaustive coverage tests every combination; t-way covers all t-tuples of parameter values; boundary covers all interesting values per parameter.
public enum CoveragePhase: Int, Comparable, Sendable {
    /// Complete enumeration of the parameter space.
    case exhaustive = 1
    /// t-way combinatorial covering (t >= 2, or strength-1 fallback).
    case tWay = 2
    /// Boundary-value coverage for large-domain parameters.
    case boundary = 3

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Identifies a coverage strategy for logging and dominance tracking.
public enum CoverageStrategyName: String, Sendable {
    case exhaustive
    case tWay
    case singleParameter
    case boundary
}

/// Shared interface for coverage construction strategies.
///
/// Each conformer wraps a specific method of building a ``CoveringArray`` from a ``FiniteDomainProfile``. ``CoverageRunner`` iterates strategies strongest-first; the first that returns a non-nil covering array wins.
///
/// Mirrors ``SequenceEncoderBase`` from the reducer, where encoders are protocol conformers dispatched by the scheduler.
public protocol CoverageStrategy {
    /// Identifies this strategy for logging.
    var name: CoverageStrategyName { get }

    /// The guarantee phase this strategy provides.
    var phase: CoveragePhase { get }

    /// Returns estimated row count for the given profile, or nil if this strategy is inapplicable (for example, exhaustive strategy for a profile exceeding the budget).
    func estimatedRows(profile: FiniteDomainProfile, budget: UInt64) -> Int?

    /// Generates a covering array, or nil if the strategy cannot produce one within budget.
    func generate(profile: FiniteDomainProfile, budget: UInt64) -> CoveringArray?
}

/// Shared interface for boundary-domain coverage strategies.
///
/// Parallel to ``CoverageStrategy`` but operates on ``BoundaryDomainProfile`` instead of ``FiniteDomainProfile``.
public protocol BoundaryCoverageStrategy {
    /// Identifies this strategy for logging.
    var name: CoverageStrategyName { get }

    /// The guarantee phase this strategy provides.
    var phase: CoveragePhase { get }

    /// Returns estimated row count for the given profile, or nil if this strategy is inapplicable.
    func estimatedRows(profile: BoundaryDomainProfile, budget: UInt64) -> Int?

    /// Generates a covering array from a boundary profile, or nil if the strategy cannot produce one within budget.
    func generate(profile: BoundaryDomainProfile, budget: UInt64) -> CoveringArray?
}
