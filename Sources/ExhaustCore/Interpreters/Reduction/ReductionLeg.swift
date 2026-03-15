/// A leg of the V-cycle, each with an independent budget.
///
/// Legs execute in declaration order within each cycle. Unused budget flows forward to subsequent legs.
public enum ReductionLeg: CaseIterable, Sendable {
    case branch
    case contravariant
    case deletion
    case covariant
    case redistribution
}
