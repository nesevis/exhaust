/// The result of a successful reduction probe.
public struct ShrinkResult<Output> {
    public let sequence: ChoiceSequence
    public let tree: ChoiceTree
    public let output: Output
    /// Number of property evaluations consumed by this application.
    public let evaluations: Int
}

/// Categorizes which kind of spans a deletion encoder targets.
enum DeletionSpanCategory {
    case containerSpans
    case sequenceElements
    case sequenceBoundaries
    case freeStandingValues
    case siblingGroups
    case mixed
}
