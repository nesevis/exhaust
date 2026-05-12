/// The result of a successful reduction probe.
package struct ReductionResult<Output> {
    /// The reduced choice sequence.
    package let sequence: ChoiceSequence
    /// The choice tree produced by materializing the reduced sequence.
    package let tree: ChoiceTree
    /// The property output produced from the reduced sequence.
    package let output: Output
    /// Number of property evaluations consumed by this application.
    package let evaluations: Int
    /// Populated for guided-mode materializations; `nil` for exact mode.
    package let decodingReport: DecodingReport?
}
