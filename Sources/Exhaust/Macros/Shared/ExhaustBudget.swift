//
//  ExhaustBudget.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/6/2026.
//

/// Controls the iteration budgets for screening and random sampling.
///
/// | Preset | Screening | Sampling |
/// |---|---|---|
/// | `.quick` | 100 | 100 |
/// | `.standard` | 200 | 200 |
/// | `.thorough` | 600 | 600 |
/// | `.extensive` | 2000 | 2000 |
///
/// Use `.standard` (the default) for development — sufficient for generators with fewer than 50 independent parameters. Use `.quick` when iteration speed matters more than screening depth. Use `.thorough` when the generator has high combinatorial complexity (many picks, nested sequences) and you want stronger screening guarantees. Use `.extensive` when counterexamples are rare or you want broad screening; expect roughly 10x the runtime of `.standard`.
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
/// For `.custom(screening:sampling:)`, the screening budget is reused as hits per direction, and `sampling` maps to max attempts per direction.
public enum ExhaustBudget: Sendable {
    /// Faster than default. Use when iteration speed matters more than screening depth.
    case quick
    /// Default for property tests and spec tests. Sufficient for most generators during development.
    case standard
    /// Stronger screening for complex generators.
    case thorough
    /// Broad screening at 10x the cost of `.standard`.
    case extensive
    /// Explicit values for all budget aspects.
    case custom(screening: Int, sampling: Int)

    /// The iteration budget for the screening phase.
    public var screeningBudget: Int {
        switch self {
            case .quick: 100
            case .standard: 200
            case .thorough: 600
            case .extensive: 2000
            case let .custom(screening, _): screening
        }
    }

    /// The iteration budget for random sampling.
    public var samplingBudget: Int {
        switch self {
            case .quick: 100
            case .standard: 200
            case .thorough: 600
            case .extensive: 2000
            case let .custom(_, sampling): sampling
        }
    }

    /// The number of matching samples each direction must accumulate before it is considered covered. Used by `#explore`.
    public var hitsPerDirection: Int {
        switch self {
            case .quick: 10
            case .standard: 30
            case .thorough: 100
            case .extensive: 300
            case let .custom(screening, _): screening
        }
    }

    /// The per-direction contribution to the shared attempt pool. Used by `#explore`.
    public var maxAttemptsPerDirection: Int {
        switch self {
            case .quick: 100
            case .standard: 300
            case .thorough: 1000
            case .extensive: 3000
            case let .custom(_, sampling): sampling
        }
    }

    /// Traps when a `.custom` budget carries negative values. Called once when a macro resolves its settings, so the accessors stay plain reads.
    func preconditionValid() {
        if case let .custom(screening, sampling) = self {
            precondition(screening >= 0, "Screening budget must be non-negative")
            precondition(sampling >= 0, "Sampling budget must be non-negative")
        }
    }

    /// Scales both screening and sampling budgets by a multiplier.
    public static func * (lhs: ExhaustBudget, rhs: Int) -> ExhaustBudget {
        precondition(rhs > 0, "Multiplier must be positive")
        return .custom(
            screening: lhs.screeningBudget * rhs,
            sampling: lhs.samplingBudget * rhs
        )
    }

    /// Scales both screening and sampling budgets by a multiplier.
    public static func * (lhs: Int, rhs: ExhaustBudget) -> ExhaustBudget {
        rhs * lhs
    }

    /// Divides both screening and sampling budgets by a divisor, flooring the results at 1.
    public static func / (lhs: ExhaustBudget, rhs: Int) -> ExhaustBudget {
        precondition(rhs > 0, "Divisor must be positive")
        return .custom(
            screening: max(1, lhs.screeningBudget / rhs),
            sampling: max(1, lhs.samplingBudget / rhs)
        )
    }
}
