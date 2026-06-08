//
//  ExhaustBudget.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/6/2026.
//

/// Controls the iteration budgets for coverage and random sampling.
///
/// | Preset | Coverage | Sampling |
/// |---|---|---|
/// | `.quick` | 100 | 100 |
/// | `.standard` | 200 | 200 |
/// | `.thorough` | 600 | 600 |
/// | `.extensive` | 2000 | 2000 |
///
/// Use `.standard` (the default) for development — sufficient for generators with fewer than 50 independent parameters. Use `.quick` when iteration speed matters more than coverage depth. Use `.thorough` when the generator has high combinatorial complexity (many picks, nested sequences) and you want stronger coverage guarantees. Use `.extensive` when counterexamples are rare or you want broad coverage; expect roughly 10x the runtime of `.standard`.
///
/// Scale any preset with arithmetic: `.thorough * 3` produces a custom budget of 1800/1800, and `.standard / 2` produces 100/100.
///
/// When used with `#explore`, the same presets map to per-direction budgets:
///
/// | Preset | Hits per direction | Max attempts per direction |
/// |---|---|---|
/// | `.quick` | 10 | 100 |
/// | `.standard` | 30 | 300 |
/// | `.thorough` | 100 | 1000 |
/// | `.extensive` | 300 | 3000 |
///
/// For `.custom(coverage:sampling:)`, `coverage` maps to hits per direction and `sampling` maps to max attempts per direction.
public enum ExhaustBudget: Sendable {
    /// Faster than default. Use when iteration speed matters more than coverage depth.
    case quick
    /// Default for property tests and contract tests. Sufficient for most generators during development.
    case standard
    /// Stronger coverage for complex generators.
    case thorough
    /// Broad coverage at 10x the cost of `.standard`.
    case extensive
    /// Explicit values for all budget aspects.
    case custom(coverage: UInt64, sampling: UInt64)

    /// The iteration budget for structured coverage analysis.
    public var coverageBudget: UInt64 {
        switch self {
            case .quick: 100
            case .standard: 200
            case .thorough: 600
            case .extensive: 2000
            case let .custom(coverage, _): coverage
        }
    }

    /// The iteration budget for random sampling.
    public var samplingBudget: UInt64 {
        switch self {
            case .quick: 100
            case .standard: 200
            case .thorough: 600
            case .extensive: 2000
            case let .custom(_, sampling):
                sampling
        }
    }

    /// The number of matching samples each direction must accumulate before it is considered covered. Used by `#explore`.
    public var hitsPerDirection: Int {
        switch self {
            case .quick: 10
            case .standard: 30
            case .thorough: 100
            case .extensive: 300
            case let .custom(coverage, _): Int(coverage)
        }
    }

    /// The per-direction contribution to the shared attempt pool. Used by `#explore`.
    public var maxAttemptsPerDirection: Int {
        switch self {
            case .quick: 100
            case .standard: 300
            case .thorough: 1000
            case .extensive: 3000
            case let .custom(_, sampling): Int(sampling)
        }
    }

    /// Scales both coverage and sampling budgets by a multiplier.
    public static func * (lhs: ExhaustBudget, rhs: UInt64) -> ExhaustBudget {
        precondition(rhs > 0, "Multiplier must be positive")
        return .custom(
            coverage: lhs.coverageBudget * rhs,
            sampling: lhs.samplingBudget * rhs
        )
    }

    /// Scales both coverage and sampling budgets by a multiplier.
    public static func * (lhs: UInt64, rhs: ExhaustBudget) -> ExhaustBudget {
        rhs * lhs
    }

    /// Divides both coverage and sampling budgets by a divisor, flooring at 1.
    public static func / (lhs: ExhaustBudget, rhs: UInt64) -> ExhaustBudget {
        let rhs = max(rhs, 1)
        return .custom(
            coverage: max(1, lhs.coverageBudget / rhs),
            sampling: max(1, lhs.samplingBudget / rhs)
        )
    }
}
