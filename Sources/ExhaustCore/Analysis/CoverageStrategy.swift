// Coverage profile protocol for structured coverage dispatch.

/// Unified interface for domain profiles used by the coverage runner.
///
/// Both ``FiniteDomainProfile`` (actual parameter values) and ``BoundaryDomainProfile`` (boundary-representative values) conform. The coverage runner uses this to pull rows from a ``PullBasedCoveringArrayGenerator`` and convert each row to a ``ChoiceTree`` for materialization.
public protocol CoverageProfile {
    /// The number of distinct values for each parameter.
    var domainSizes: [UInt64] { get }

    /// The number of parameters.
    var parameterCount: Int { get }

    /// The total combinatorial space (product of domain sizes, capped at `UInt64.max` on overflow).
    var totalSpace: UInt64 { get }

    /// Converts a covering array row (value indices per parameter) into a ``ChoiceTree`` for materialization, or `nil` if the row cannot be replayed (for example, element values at sequence length zero).
    func buildTree(from row: CoveringArrayRow) -> ChoiceTree?
}
