/// Statistics collected from a single Bonsai reduction run.
///
/// Captures per-encoder probe counts, materialization attempts, per-fingerprint filter validity observations, and profiling data for the reduction planning decision tree. Accumulated monotonically by ``ReductionState`` during reduction and extracted at the end of the pipeline.
public struct ReductionStats: Sendable {
    /// Per-encoder probe counts accumulated across all cycles. Total probes emitted by each encoder, including those that hit the reject cache.
    public var encoderProbes: [EncoderName: Int]

    /// Per-encoder probe counts that were accepted (the decoder produced a valid shrink).
    public var encoderProbesAccepted: [EncoderName: Int]

    /// Per-encoder probe counts that hit the reject cache before decoding (no materialization).
    public var encoderProbesRejectedByCache: [EncoderName: Int]

    /// Per-encoder probe counts that were materialized but rejected by the decoder (failed shortlex check, filter rejection, range violation, decode error, or property still passes). Each such probe consumes one materialization without a property invocation — the "wasted mats" gap between Bonsai and Graph.
    public var encoderProbesRejectedByDecoder: [EncoderName: Int]

    /// Total materialization attempts (decoder invocations) during reduction.
    public var totalMaterializations: Int

    /// Total reduction cycles completed.
    public var cycles: Int

    // MARK: - Floor Re-Confirmation Profiling (Decision Tree: Step 1)

    /// Number of coordinates that had cached convergence floors at the start of Phase 2 in each cycle.
    ///
    /// If this equals the total coordinate count, Phase 2 is entirely re-confirmation. The ratio `convergedCoordinatesAtPhaseTwoStart / totalValueCoordinates` approximates the fraction of Phase 2 probes spent on re-confirmation.
    public var convergedCoordinatesAtPhaseTwoStart: Int

    /// Total value coordinates in the sequence at Phase 2 start (denominator for the re-confirmation ratio).
    public var totalValueCoordinatesAtPhaseTwoStart: Int

    // MARK: - Wrong Encoder Selection Profiling (Decision Tree: Steps 2+3)

    /// Number of times ``FibreCoveringEncoder`` discovered a fibre > 64 at `start()` time (exhaustive selected but fibre was too large, fell back to pairwise or produced no probes).
    public var fibreExceededExhaustiveThreshold: Int

    /// Number of downstream starts using exhaustive enumeration (fibre ≤ 64).
    public var pairwiseOnExhaustibleFibre: Int

    /// Number of downstream starts using ZeroValue fallback (fibre too large for covering).
    public var fibreZeroValueStarts: Int

    /// Number of times a ``KleisliComposition`` in the exploration leg produced zero accepted probes within budget (composition was futile for this edge).
    public var futileCompositions: Int

    /// Total ``KleisliComposition`` edges attempted in the exploration leg.
    public var compositionEdgesAttempted: Int

    // MARK: - Convergence Transfer Profiling (Decision Tree: Steps 4+5)

    /// Number of convergence transfers attempted (driver validated pending origins).
    public var convergenceTransfersAttempted: Int

    /// Number of convergence transfers where all origins passed floor-1 validation.
    public var convergenceTransfersValidated: Int

    /// Number of convergence transfers where at least one origin was stale (floor-1 failed).
    public var convergenceTransfersStale: Int

    // MARK: - Post-Termination Verification

    /// Number of probes used by the post-termination verification sweep.
    public var verificationSweepProbes: Int

    /// Whether the verification sweep detected cache staleness.
    public var verificationSweepFoundStaleness: Bool

    // MARK: - Fibre Prediction Accuracy (Decision Tree: Step 2)

    /// Number of composition edges where the pre-lift fibre size prediction matched the actual encoder mode.
    public var fibrePredictionCorrect: Int

    /// Number of composition edges where the prediction disagreed with the actual encoder mode.
    public var fibrePredictionWrong: Int

    // MARK: - Convergence Signal Counts

    /// Number of coordinates where zero-value batch zeroing failed but individual zeroing succeeded.
    public var zeroingDependencyCount: Int

    /// Number of composition edges where the downstream exhaustively searched the fibre and found no failure.
    public var fibreExhaustedCleanCount: Int

    /// Number of composition edges where the downstream exhaustively searched the fibre and found a failure.
    public var fibreExhaustedWithFailureCount: Int

    /// Number of composition edges where the downstream bailed before completing coverage.
    public var fibreBailCount: Int

    // MARK: - Filter Observations

    /// Per-fingerprint filter predicate observations accumulated across all materializations.
    public var filterObservations: [UInt64: FilterObservation] = [:]

    // MARK: - Graph Reducer

    /// Node count at initial graph construction. Zero when using the Bonsai path.
    public var graphNodeCount: Int = 0

    /// Edge counts per layer at initial graph construction.
    public var graphDependencyEdgeCount: Int = 0
    public var graphContainmentEdgeCount: Int = 0
    public var graphSelfSimilarityEdgeCount: Int = 0

    /// Number of graph rebuilds during reduction (structural changes that triggered a fresh `ChoiceGraph.build`).
    public var graphRebuilds: Int = 0

    /// Deletion antichain size at first cycle.
    public var graphDeletionAntichainSize: Int = 0

    // MARK: - Per-Phase Outcomes

    /// Per-cycle phase outcome data, collected when stats collection is enabled.
    public var cycleOutcomes: [CycleOutcome] = []

    /// Creates an empty stats value.
    public init() {
        encoderProbes = [:]
        encoderProbesAccepted = [:]
        encoderProbesRejectedByCache = [:]
        encoderProbesRejectedByDecoder = [:]
        totalMaterializations = 0
        cycles = 0
        convergedCoordinatesAtPhaseTwoStart = 0
        totalValueCoordinatesAtPhaseTwoStart = 0
        fibreExceededExhaustiveThreshold = 0
        pairwiseOnExhaustibleFibre = 0
        fibreZeroValueStarts = 0
        futileCompositions = 0
        compositionEdgesAttempted = 0
        convergenceTransfersAttempted = 0
        convergenceTransfersValidated = 0
        convergenceTransfersStale = 0
        verificationSweepProbes = 0
        verificationSweepFoundStaleness = false
        fibrePredictionCorrect = 0
        fibrePredictionWrong = 0
        zeroingDependencyCount = 0
        fibreExhaustedCleanCount = 0
        fibreExhaustedWithFailureCount = 0
        fibreBailCount = 0
    }
}
