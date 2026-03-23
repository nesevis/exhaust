import ExhaustCore

/// Run statistics from a single `#exhaust` invocation.
///
/// Delivered via the ``ExhaustSettings/onReport(_:)`` setting. Contains phase timing, invocation counts, per-encoder probe breakdown, and profiling data for the reduction planning decision tree.
public struct ExhaustReport: Sendable {
    /// Time spent in the structured coverage phase, in milliseconds.
    public var coverageMilliseconds: Double = 0

    /// Time spent in the random generation phase, in milliseconds.
    public var generationMilliseconds: Double = 0

    /// Time spent in the reduction phase, in milliseconds.
    public var reductionMilliseconds: Double = 0

    /// Time spent in reflection (only populated for the `.reflecting` path), in milliseconds.
    public var reflectionMilliseconds: Double = 0

    /// Total wall-clock time, in milliseconds.
    public var totalMilliseconds: Double = 0

    /// Total property invocations across all phases (coverage, random sampling, and reduction).
    public var propertyInvocations: Int = 0

    /// Total materialization attempts (decoder invocations) during the reduction phase.
    public var totalMaterializations: Int = 0

    /// Per-encoder probe counts from the reduction phase.
    ///
    /// Each key is an ``EncoderName`` identifying a reduction encoder, and the value is the total number of probes that encoder generated across all cycles.
    public var encoderProbes: [EncoderName: Int] = [:]

    /// Total reduction cycles completed.
    public var cycles: Int = 0

    // MARK: - Decision Tree Profiling

    /// Number of coordinates with cached convergence floors at Phase 2 start (cumulative across cycles).
    public var convergedCoordinatesAtPhaseTwoStart: Int = 0

    /// Total value coordinates at Phase 2 start (cumulative across cycles — denominator for re-confirmation ratio).
    public var totalValueCoordinatesAtPhaseTwoStart: Int = 0

    /// Times the fibre covering encoder discovered a fibre > 64 at `start()` (exhaustive selected, fibre too large).
    public var fibreExceededExhaustiveThreshold: Int = 0

    /// Times pairwise ran on a fibre ≤ 64 (pairwise selected, exhaustive would have worked).
    public var pairwiseOnExhaustibleFibre: Int = 0

    /// Number of downstream starts using ZeroValue fallback (fibre too large for covering).
    public var fibreZeroValueStarts: Int = 0

    /// Compositions that produced zero accepted probes within budget.
    public var futileCompositions: Int = 0

    /// Total composition edges attempted.
    public var compositionEdgesAttempted: Int = 0

    /// Convergence transfers attempted (driver validated pending origins).
    public var convergenceTransfersAttempted: Int = 0

    /// Convergence transfers where all origins passed floor-1 validation.
    public var convergenceTransfersValidated: Int = 0

    /// Convergence transfers where at least one origin was stale.
    public var convergenceTransfersStale: Int = 0

    /// Probes used by the post-termination verification sweep.
    public var verificationSweepProbes: Int = 0

    /// Whether the verification sweep detected cache staleness.
    public var verificationSweepFoundStaleness: Bool = false

    /// Composition edges where the pre-lift fibre prediction matched the actual encoder mode.
    public var fibrePredictionCorrect: Int = 0

    /// Composition edges where the pre-lift fibre prediction disagreed with the actual encoder mode.
    public var fibrePredictionWrong: Int = 0

    /// One-line summary of profiling data for the reduction planning decision tree.
    public var profilingSummary: String {
        let reconfirmRatio = totalValueCoordinatesAtPhaseTwoStart > 0
            ? String(format: "%.0f%%", Double(convergedCoordinatesAtPhaseTwoStart) / Double(totalValueCoordinatesAtPhaseTwoStart) * 100)
            : "n/a"
        let predictionTotal = fibrePredictionCorrect + fibrePredictionWrong
        let predictionLabel = predictionTotal > 0
            ? "\(fibrePredictionCorrect)/\(predictionTotal)"
            : "n/a"
        return "cycles=\(cycles) probes=\(propertyInvocations) mats=\(totalMaterializations) reconfirm=\(reconfirmRatio) edges=\(compositionEdgesAttempted) futile=\(futileCompositions) fibre=\(pairwiseOnExhaustibleFibre)e/\(fibreExceededExhaustiveThreshold)p/\(fibreZeroValueStarts)z predict=\(predictionLabel) transfers=\(convergenceTransfersAttempted)/\(convergenceTransfersValidated)/\(convergenceTransfersStale) sweep=\(verificationSweepProbes)p/\(verificationSweepFoundStaleness ? "stale" : "ok")"
    }

    /// Populates reduction statistics from a ``ReductionStats`` value.
    public mutating func applyReductionStats(_ stats: ReductionStats) {
        encoderProbes = stats.encoderProbes
        totalMaterializations = stats.totalMaterializations
        cycles = stats.cycles
        convergedCoordinatesAtPhaseTwoStart = stats.convergedCoordinatesAtPhaseTwoStart
        totalValueCoordinatesAtPhaseTwoStart = stats.totalValueCoordinatesAtPhaseTwoStart
        fibreExceededExhaustiveThreshold = stats.fibreExceededExhaustiveThreshold
        pairwiseOnExhaustibleFibre = stats.pairwiseOnExhaustibleFibre
        futileCompositions = stats.futileCompositions
        compositionEdgesAttempted = stats.compositionEdgesAttempted
        convergenceTransfersAttempted = stats.convergenceTransfersAttempted
        convergenceTransfersValidated = stats.convergenceTransfersValidated
        convergenceTransfersStale = stats.convergenceTransfersStale
        verificationSweepProbes = stats.verificationSweepProbes
        verificationSweepFoundStaleness = stats.verificationSweepFoundStaleness
        fibrePredictionCorrect = stats.fibrePredictionCorrect
        fibrePredictionWrong = stats.fibrePredictionWrong
        fibreZeroValueStarts = stats.fibreZeroValueStarts
    }
}
