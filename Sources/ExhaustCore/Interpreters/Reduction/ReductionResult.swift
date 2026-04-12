/// The result of a successful reduction probe.
public struct ReductionResult<Output> {
    public let sequence: ChoiceSequence
    public let tree: ChoiceTree
    public let output: Output
    /// Number of property evaluations consumed by this application.
    public let evaluations: Int
    /// Populated for guided-mode materializations; `nil` for exact mode.
    public let decodingReport: DecodingReport?
}
