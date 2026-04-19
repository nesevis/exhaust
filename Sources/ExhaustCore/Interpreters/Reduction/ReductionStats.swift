/// Statistics collected from a single reduction run.
///
/// Captures per-encoder probe counts, materialization attempts, per-fingerprint filter validity observations, and profiling data for the reduction planning decision tree. Accumulated monotonically by ``ReductionState`` during reduction and extracted at the end of the pipeline.
public struct ReductionStats: Sendable {
    /// Per-encoder probe counts accumulated across all cycles. Total probes emitted by each encoder, including those that hit the reject cache.
    public var encoderProbes: [EncoderName: Int]

    /// Per-encoder probe counts that were accepted (the decoder produced a valid shrink).
    public var encoderProbesAccepted: [EncoderName: Int]

    /// Per-encoder probe counts that hit the reject cache before decoding (no materialization).
    public var encoderProbesRejectedByCache: [EncoderName: Int]

    /// Per-encoder probe counts that were materialized but rejected by the decoder (failed shortlex check, filter rejection, range violation, decode error, or property still passes). Each such probe consumes one materialization without a property invocation.
    public var encoderProbesRejectedByDecoder: [EncoderName: Int]

    /// Total materialization attempts (decoder invocations) during reduction.
    public var totalMaterializations: Int

    /// Total reduction cycles completed.
    public var cycles: Int

    // MARK: - Filter Observations

    /// Per-fingerprint filter predicate observations accumulated across all materializations.
    public var filterObservations: [UInt64: FilterObservation] = [:]

    // MARK: - Graph Reducer

    /// Graph structure and lifecycle statistics accumulated during reduction.
    public var graphStats: ChoiceGraphStats

    // MARK: - Probe Log

    /// Per-dispatch records of yield-based scope dispatches. Empty unless ``Interpreters/ReducerConfiguration/collectProbeLog`` is `true`. Populated only at the standard yield-merge dispatch site; bound value, low-shortcut, and convergence-confirmation dispatches are not recorded.
    public var probeLog: [ProbeLogEntry] = []

    /// Creates an empty stats value.
    public init() {
        encoderProbes = [:]
        encoderProbesAccepted = [:]
        encoderProbesRejectedByCache = [:]
        encoderProbesRejectedByDecoder = [:]
        totalMaterializations = 0
        cycles = 0
        graphStats = ChoiceGraphStats()
    }
}

// MARK: - Probe Log Entry

/// One record per standard yield-merge dispatch from ``ChoiceGraphScheduler``.
///
/// Used to evaluate whether the scheduler's ``TransformationYield`` ranking is well-calibrated against realized acceptance. The yield components are decomposed into primitive fields so the entry stays public without leaking the package-internal yield type.
public struct ProbeLogEntry: Sendable {
    /// One-based cycle index in which the dispatch occurred.
    public var cycle: Int

    /// Encoder family selected for the dispatch.
    public var encoder: EncoderName

    /// Predicted structural yield (sequence positions removed). Higher is preferred.
    public var predictedStructuralYield: Int

    /// Predicted value yield (bound subtree size unlocked by minimization). Higher is preferred.
    public var predictedValueYield: Int

    /// Approximation slack additive component. Zero for exact reductions.
    public var predictedSlackAdditive: Int

    /// Estimated number of probes the encoder will need.
    public var estimatedProbes: Int

    /// Number of probes the encoder actually attempted in this dispatch.
    public var probeCount: Int

    /// Number of probes the decoder accepted in this dispatch.
    public var acceptCount: Int

    /// Sequence length immediately before the dispatch.
    public var sequenceLengthBefore: Int

    /// Sequence length immediately after the dispatch.
    public var sequenceLengthAfter: Int

    /// Creates a probe log entry.
    public init(
        cycle: Int,
        encoder: EncoderName,
        predictedStructuralYield: Int,
        predictedValueYield: Int,
        predictedSlackAdditive: Int,
        estimatedProbes: Int,
        probeCount: Int,
        acceptCount: Int,
        sequenceLengthBefore: Int,
        sequenceLengthAfter: Int
    ) {
        self.cycle = cycle
        self.encoder = encoder
        self.predictedStructuralYield = predictedStructuralYield
        self.predictedValueYield = predictedValueYield
        self.predictedSlackAdditive = predictedSlackAdditive
        self.estimatedProbes = estimatedProbes
        self.probeCount = probeCount
        self.acceptCount = acceptCount
        self.sequenceLengthBefore = sequenceLengthBefore
        self.sequenceLengthAfter = sequenceLengthAfter
    }
}
