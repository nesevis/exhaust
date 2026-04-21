/// The result of a successful reduction probe.
package struct ReductionResult<Output> {
    /// The reduced choice sequence.
    public let sequence: ChoiceSequence
    /// The choice tree produced by materializing the reduced sequence.
    public let tree: ChoiceTree
    /// The property output produced from the reduced sequence.
    public let output: Output
    /// Number of property evaluations consumed by this application.
    public let evaluations: Int
    /// Populated for guided-mode materializations; `nil` for exact mode.
    public let decodingReport: DecodingReport?
}
