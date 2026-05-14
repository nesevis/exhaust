/// Statistics collected from a single reduction run.
///
/// Captures per-encoder probe counts, materialization attempts, per-fingerprint filter validity observations, and profiling data for the reduction planning decision tree. Accumulated monotonically by ``ReductionMachine`` during reduction and extracted at the end of the pipeline.
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

    /// Aggregate wall-time spent in each ``ReductionMachine`` step category, in nanoseconds.
    package var stepTimings: StepTimings = .init()

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

// MARK: - Step Timings

extension ReductionStats {
    /// Aggregate wall-time spent in each ``ReductionMachine`` step category.
    ///
    /// Times are in nanoseconds. Populated by the driver loop that calls ``ReductionMachine/next()`` and measures the elapsed time per step.
    package struct StepTimings: Sendable {
        package var evaluate: UInt64 = 0
        package var encode: UInt64 = 0
        package var decode: UInt64 = 0
        package var rebuild: UInt64 = 0
        package var convergenceConfirmation: UInt64 = 0
        package var relaxRound: UInt64 = 0
        package var reorder: UInt64 = 0

        package var evaluateCount: Int = 0
        package var encodeCount: Int = 0
        package var decodeCount: Int = 0
        package var rebuildCount: Int = 0

        package init() {}

        /// Records elapsed time for a step transition.
        package mutating func record(_ transition: ReductionMachine.Transition, elapsed: UInt64) {
            switch transition {
            case .evaluated:
                evaluate += elapsed
                evaluateCount += 1
            case .encoded:
                encode += elapsed
                encodeCount += 1
            case .decoded:
                decode += elapsed
                decodeCount += 1
            case .rebuilt:
                rebuild += elapsed
                rebuildCount += 1
            case .convergenceConfirmed:
                convergenceConfirmation += elapsed
            case .relaxRoundCompleted:
                relaxRound += elapsed
            case .reorderCompleted:
                reorder += elapsed
            case .cycleStarted, .cycleEnded, .deferralReleased, .terminated:
                break
            }
        }
    }
}
