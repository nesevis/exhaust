/// Statistics collected from a single Bonsai reduction run.
///
/// Captures per-encoder probe counts and total materialization attempts across all cycles. Accumulated monotonically by ``ReductionState`` during reduction and extracted at the end of the pipeline.
public struct ReductionStats: Sendable {
    /// Per-encoder probe counts accumulated across all cycles.
    public var encoderProbes: [EncoderName: Int]

    /// Total materialization attempts (decoder invocations) during reduction.
    public var totalMaterializations: Int

    /// Creates an empty stats value.
    public init() {
        encoderProbes = [:]
        totalMaterializations = 0
    }
}
