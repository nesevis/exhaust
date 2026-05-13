/// Statistics collected from a single reduction run.
///
/// Captures per-encoder probe counts, materialization attempts, per-fingerprint filter validity observations, and profiling data for the reduction planning decision tree. Accumulated monotonically by ``ReductionState`` during reduction and extracted at the end of the pipeline.
@usableFromInline
package struct ReductionStats: Sendable {
    /// Per-encoder probe counts accumulated across all cycles. Total probes emitted by each encoder, including those that hit the reject cache.
    package var encoderProbes: [EncoderName: Int]

    /// Per-encoder probe counts that were accepted (the decoder produced a valid shrink).
    package var encoderProbesAccepted: [EncoderName: Int]

    /// Per-encoder probe counts that hit the reject cache before decoding (no materialization).
    package var encoderProbesRejectedByCache: [EncoderName: Int]

    /// Per-encoder probe counts that were materialized but rejected by the decoder (failed shortlex check, filter rejection, range violation, decode error, or property still passes). Each such probe consumes one materialization without a property invocation.
    package var encoderProbesRejectedByDecoder: [EncoderName: Int]

    /// Total materialization attempts (decoder invocations) during reduction.
    package var totalMaterializations: Int

    /// Total reduction cycles completed.
    package var cycles: Int

    // MARK: - Filter Observations

    /// Per-fingerprint filter predicate observations accumulated across all materializations.
    package var filterObservations: [UInt64: FilterObservation] = [:]

    // MARK: - Graph Reducer

    /// Graph structure and lifecycle statistics accumulated during reduction.
    package var graphStats: ChoiceGraphStats

    /// Creates an empty stats value.
    package init() {
        encoderProbes = [:]
        encoderProbesAccepted = [:]
        encoderProbesRejectedByCache = [:]
        encoderProbesRejectedByDecoder = [:]
        totalMaterializations = 0
        cycles = 0
        graphStats = ChoiceGraphStats()
    }
}
