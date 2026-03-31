//
//  FilterType.swift
//  Exhaust
//
//  Created by Chris Kolbu on 26/2/2026.
//

/// Strategy used by the `filter` combinator to satisfy its predicate.
public enum FilterType: Equatable, Hashable, CaseIterable {
    /// Selects a strategy automatically based on generator structure.
    /// Uses ``choiceGradientSampling`` to tune pick weights via CGS with fitness sharing, producing the best balance of validity rate and output diversity.
    case auto

    /// Rejection sampling: generate values and discard those that fail the predicate.
    /// Simple and predictable, but inefficient when valid values are sparse.
    case rejectionSampling

    /// Probes each branching point's choices through the continuation pipeline to measure predicate satisfaction rates, then biases weights toward valid outputs before generation begins.
    case probeSampling

    /// Uses online CGS derivative sampling to condition pick weights on upstream choices, then bakes them with fitness sharing to prevent overcommitting to the dominant cluster. Produces the best-quality outputs for recursive generators (e.g. BSTs, AVL trees) at the cost of a short warmup pass.
    case choiceGradientSampling
}

// MARK: - Filter Observation

/// Per-fingerprint filter predicate observation counts.
///
/// Tracks how many times a filter's predicate was evaluated (``attempts``) and how many of those evaluations returned true (``passes``). Accumulated during generation and reduction to measure filter constraint tightness.
public struct FilterObservation: Sendable {
    /// Number of times the filter predicate was evaluated.
    public var attempts: Int = 0

    /// Number of times the filter predicate returned true.
    public var passes: Int = 0

    /// Fraction of attempts that passed, or zero if no attempts were recorded.
    public var validityRate: Double {
        attempts > 0 ? Double(passes) / Double(attempts) : 0.0
    }

    /// Records a single predicate evaluation.
    public mutating func recordAttempt(passed: Bool) {
        attempts += 1
        if passed { passes += 1 }
    }
}
