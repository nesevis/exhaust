/// The categorical type of a reduction phase.
///
/// Phases are ordered by guarantee strength. Within each phase, encoders are ordered by the 2-cell preorder. Raw values match the prose numbering to avoid off-by-one confusion.
public enum ReductionPhase: Int, Comparable, CaseIterable, Sendable {
    /// Encoder `.exact`; morphism `.bounded` via decoder.
    case structuralDeletion = 1
    /// Encoder `.exact`; morphism `.exact` or `.bounded` via decoder.
    case valueMinimization = 2
    /// Encoder `.exact`; morphism `.exact` or `.bounded` via decoder.
    case reordering = 3
    /// Encoder `.bounded`.
    case redistribution = 4
    /// Encoder `.speculative`.
    case exploration = 5

    public static func < (lhs: ReductionPhase, rhs: ReductionPhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
