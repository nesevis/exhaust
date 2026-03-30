/// The categorical type of a reduction phase.
///
/// Phases are ordered by guarantee strength. Within each phase, encoders are ordered by the 2-cell preorder. Raw values match the prose numbering to avoid off-by-one confusion.
public enum ReductionPhase: Int, CaseIterable, Sendable {
    /// Encoder `.exact`; morphism `.bounded` via decoder.
    case structuralDeletion
    /// Encoder `.exact`; morphism `.exact` or `.bounded` via decoder.
    case valueMinimization
    /// Encoder `.bounded`.
    case redistribution
    /// Encoder `.speculative`.
    case exploration
}
