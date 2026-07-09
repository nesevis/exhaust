//
//  FilterType.swift
//  Exhaust
//
//  Created by Chris Kolbu on 26/2/2026.
//

/// Strategy used by the `filter` combinator to satisfy its predicate.
public enum FilterType: Sendable, Equatable, Hashable {
    /// Selects a strategy automatically based on generator structure.
    /// Uses ``choiceGradientSampling`` to tune pick weights via CGS with fitness sharing, producing the best balance of validity rate and output diversity.
    case auto

    /// Rejection sampling: generate values and discard those that fail the predicate.
    /// Simple and predictable, but inefficient when valid values are sparse.
    case rejectionSampling

    /// Probes each branching point's choices through the continuation pipeline to measure predicate satisfaction rates, then biases weights toward valid outputs before generation begins.
    case probeSampling

    /// Uses online CGS derivative sampling to condition pick weights on upstream choices, then bakes them with fitness sharing to prevent overcommitting to the dominant cluster. Produces the best-quality outputs for recursive generators (for example BSTs, AVL trees) at the cost of a short warmup pass.
    case choiceGradientSampling
}

package extension FilterType {
    /// Short display label for diagnostic output.
    var shortDescription: String {
        switch self {
            case .auto: FilterType.choiceGradientSampling.shortDescription
            case .rejectionSampling: "rejection"
            case .probeSampling: "probe"
            case .choiceGradientSampling: "CGS"
        }
    }
}

// MARK: - Filter Source Location

/// Source location captured at a ``Generator/filter(_:_:fileID:filePath:line:column:)`` call site.
///
/// Stored alongside filter observations so that runtime warnings can point to the `.filter(...)` line rather than the `#exhaust` macro site.
public struct FilterSourceLocation: @unchecked Sendable {
    /// The `#fileID` of the filter call site.
    public let fileID: StaticString
    /// The `#filePath` of the filter call site.
    public let filePath: StaticString
    /// The `#line` of the filter call site.
    public let line: UInt
    /// The `#column` of the filter call site.
    public let column: UInt
    /// Called when the filter exhausts its retry budget without producing a valid value.
    public let onBudgetExhausted: (() -> Void)?

    public init(
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        onBudgetExhausted: (() -> Void)? = nil
    ) {
        self.fileID = fileID
        self.filePath = filePath
        self.line = line
        self.column = column
        self.onBudgetExhausted = onBudgetExhausted
    }
}

// MARK: - Filter Observation

/// Per-fingerprint filter predicate observation counts.
///
/// Tracks how many times a filter's predicate was evaluated (``attempts``) and how many of those evaluations returned true (``passes``). Accumulated during generation and reduction to measure filter constraint tightness.
///
/// - SeeAlso: ``FitnessAccumulator`` (per-choice fitness during CGS warmup), ``CoOccurrenceMatrix`` (per-direction pairwise membership during exploration). All three accumulate empirical outcome counts over generator samples at different granularities.
public struct FilterObservation: Sendable {
    /// Number of times the filter predicate was evaluated.
    public var attempts: Int = 0

    /// Number of times the filter predicate returned true.
    public var passes: Int = 0

    /// Source location of the `.filter(...)` call that created this observation.
    public var sourceLocation: FilterSourceLocation?

    /// Strategy used by the filter that produced this observation.
    public var filterType: FilterType?

    /// Creates a filter observation with the given attempt and pass counts.
    public init(attempts: Int = 0, passes: Int = 0, sourceLocation: FilterSourceLocation? = nil, filterType: FilterType? = nil) {
        self.attempts = attempts
        self.passes = passes
        self.sourceLocation = sourceLocation
        self.filterType = filterType
    }

    /// Fraction of attempts that passed, or zero if no attempts were recorded.
    public var validityRate: Double {
        attempts > 0 ? Double(passes) / Double(attempts) : 0.0
    }

    /// Records a single predicate evaluation.
    public mutating func recordAttempt(passed: Bool) {
        attempts += 1
        if passed { passes += 1 }
    }

    /// Merges another observation into this one by summing counters.
    public mutating func merge(_ other: FilterObservation) {
        attempts += other.attempts
        passes += other.passes
        if sourceLocation == nil { sourceLocation = other.sourceLocation }
    }
}
