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

/// Result of boundary coverage generation: either a single flat covering array or
/// per-length sub-arrays for profiles with sequence parameters.
public enum BoundaryCoverageResult {
    /// Standard flat IPOG covering array (no sequence parameters, or multi-sequence fallback).
    case flat(CoveringArray)
    /// Per-length partitioned sub-arrays, each with its own profile containing only accessible parameters.
    case perLength(subArrays: [(rows: [CoveringArrayRow], profile: BoundaryDomainProfile)])

    /// The IPOG strength of the result. For per-length results, this is the maximum strength
    /// across sub-arrays (typically 2 when a length=2 sub-array is present).
    public var strength: Int {
        switch self {
        case let .flat(covering):
            covering.strength
        case let .perLength(subArrays):
            // Sub-arrays with more params have higher strength from IPOG.
            // Minimum meaningful strength is 1.
            subArrays.isEmpty ? 0 : max(subArrays.map(\.profile.parameters.count).max() ?? 0, 1)
        }
    }

    /// Total number of rows across all sub-arrays.
    public var totalRows: Int {
        switch self {
        case let .flat(covering):
            covering.rows.count
        case let .perLength(subArrays):
            subArrays.reduce(0) { $0 + $1.rows.count }
        }
    }
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

    /// Generates boundary coverage, or nil if the strategy cannot produce anything within budget.
    func generate(profile: BoundaryDomainProfile, budget: UInt64) -> BoundaryCoverageResult?
}
