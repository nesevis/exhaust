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
