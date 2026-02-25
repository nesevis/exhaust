//
//  FilterType.swift
//  Exhaust
//
//  Created by Chris Kolbu on 26/2/2026.
//

/// Strategy used by the `filter` combinator to satisfy its predicate.
public enum FilterType: Equatable, Hashable, CaseIterable {
    /// Selects a strategy automatically based on generator structure.
    /// Uses ``tune`` when the generator contains branching points, otherwise
    /// falls back to ``reject``.
    case auto

    /// Rejection sampling: generate values and discard those that fail the predicate.
    case reject

    /// Probes each branching point's choices through the continuation pipeline to measure
    /// predicate satisfaction rates, then biases weights toward valid outputs before
    /// generation begins.
    case tune
}
