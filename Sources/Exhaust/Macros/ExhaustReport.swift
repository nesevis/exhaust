import ExhaustCore

/// Run statistics from a single `#exhaust` invocation.
///
/// Delivered via the ``ExhaustSettings/onReport(_:)`` setting. Contains phase timing, invocation counts, per-encoder probe breakdown, per-fingerprint filter validity observations, and profiling data for the reduction planning decision tree.
public struct ExhaustReport: Sendable {
    /// The PRNG seed used for random sampling, if any.
    public var seed: UInt64?

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

    /// Property invocations during the structured coverage phase.
    public var coverageInvocations: Int = 0

    /// Property invocations during the random sampling phase.
    public var randomSamplingInvocations: Int = 0

    /// Property invocations during the reduction phase (counted by the wrapping closure).
    public var reductionInvocations: Int = 0

    /// Sets the per-phase property invocation counts and derives the total.
    public mutating func setInvocations(
        coverage: Int,
        randomSampling: Int,
        reduction: Int
    ) {
        coverageInvocations = coverage
        randomSamplingInvocations = randomSampling
        reductionInvocations = reduction
        propertyInvocations = coverage + randomSampling + reduction
    }

    /// Total materialization attempts (decoder invocations) during the reduction phase.
    public var totalMaterializations: Int = 0

    /// Per-encoder probe counts from the reduction phase.
    ///
    /// Each key is an ``EncoderName`` identifying a reduction encoder, and the value is the total number of probes that encoder generated across all cycles.
    /// **Includes cache rejections that did not lead to a materialization**
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

    // MARK: - Convergence Signal Counts

    /// Coordinates where zero-value batch zeroing failed but individual zeroing succeeded.
    public var zeroingDependencyCount: Int = 0

    /// Composition edges where the downstream exhaustively searched the fibre and found no failure.
    public var fibreExhaustedCleanCount: Int = 0

    /// Composition edges where the downstream exhaustively searched the fibre and found a failure.
    public var fibreExhaustedWithFailureCount: Int = 0

    /// Composition edges where the downstream bailed before completing coverage.
    public var fibreBailCount: Int = 0

    /// Per-fingerprint filter predicate observations accumulated during reduction.
    public var filterObservations: [UInt64: FilterObservation] = [:]

    /// Per-cycle phase outcome data.
    public var cycleOutcomes: [CycleOutcome] = []

    /// One-line summary of per-phase invocations and acceptances aggregated across all cycles.
    public var phaseSummary: String {
        var phaseInvocations: [ReducerPhaseIdentifier: Int] = [:]
        var phaseAcceptances: [ReducerPhaseIdentifier: Int] = [:]
        var phaseStructural: [ReducerPhaseIdentifier: Int] = [:]
        for outcome in cycleOutcomes {
            for (phase, disposition) in [
                (ReducerPhaseIdentifier.baseDescent, outcome.baseDescent),
                (.fibreDescent, outcome.fibreDescent),
                (.exploration, outcome.exploration),
            ] {
                if case let .ran(phaseOutcome) = disposition {
                    phaseInvocations[phase, default: 0] += phaseOutcome.propertyInvocations
                    phaseAcceptances[phase, default: 0] += phaseOutcome.acceptances
                    phaseStructural[phase, default: 0] += phaseOutcome.structuralAcceptances
                }
            }
        }
        func label(_ phase: ReducerPhaseIdentifier, _ tag: String) -> String {
            let invocations = phaseInvocations[phase, default: 0]
            let structural = phaseStructural[phase, default: 0]
            let value = phaseAcceptances[phase, default: 0] - structural
            guard invocations > 0 else { return "" }
            return " \(tag):\(invocations)/\(structural)s+\(value)v"
        }
        let parts = [
            label(.baseDescent, "B"),
            label(.fibreDescent, "F"),
            label(.exploration, "E"),
        ]
        let joined = parts.joined()
        return joined.isEmpty ? "" : "phases=\(joined.dropFirst())"
    }

    /// One-line summary of profiling data for the reduction planning decision tree.
    public var profilingSummary: String {
        let reconfirmRatio = totalValueCoordinatesAtPhaseTwoStart > 0
            ? String(format: "%.0f%%", Double(convergedCoordinatesAtPhaseTwoStart) / Double(totalValueCoordinatesAtPhaseTwoStart) * 100)
            : "n/a"
        let predictionTotal = fibrePredictionCorrect + fibrePredictionWrong
        let predictionLabel = predictionTotal > 0
            ? "\(fibrePredictionCorrect)/\(predictionTotal)"
            : "n/a"
        let hasSignals =
            zeroingDependencyCount > 0
                || fibreExhaustedCleanCount > 0
                || fibreBailCount > 0
        let signalLabel = hasSignals
            ? " signals=\(zeroingDependencyCount)dep/\(fibreExhaustedCleanCount)clean/\(fibreExhaustedWithFailureCount)fail/\(fibreBailCount)bail"
            : ""
        let phaseLabel = phaseSummary.isEmpty ? "" : " \(phaseSummary)"
        let projectionProbes = encoderProbes[.freeCoordinateProjection] ?? 0
        let humanOrderProbes = encoderProbes[.humanOrderReorder] ?? 0
        let hasPassData = projectionProbes > 0 || humanOrderProbes > 0
        let passLabel = hasPassData
            ? " passes=\(projectionProbes)proj/\(humanOrderProbes)human"
            : ""
        return "cycles=\(cycles) probes=\(coverageInvocations)cov/\(randomSamplingInvocations)rand/\(reductionInvocations)red mats=\(totalMaterializations) reconfirm=\(reconfirmRatio) edges=\(compositionEdgesAttempted) futile=\(futileCompositions) fibre=\(pairwiseOnExhaustibleFibre)e/\(fibreExceededExhaustiveThreshold)p/\(fibreZeroValueStarts)z predict=\(predictionLabel) transfers=\(convergenceTransfersAttempted)/\(convergenceTransfersValidated)/\(convergenceTransfersStale) sweep=\(verificationSweepProbes)p/\(verificationSweepFoundStaleness ? "stale" : "ok")\(signalLabel)\(passLabel)\(phaseLabel)"
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
        zeroingDependencyCount = stats.zeroingDependencyCount
        fibreExhaustedCleanCount = stats.fibreExhaustedCleanCount
        fibreExhaustedWithFailureCount = stats.fibreExhaustedWithFailureCount
        fibreBailCount = stats.fibreBailCount
        filterObservations = stats.filterObservations
        cycleOutcomes = stats.cycleOutcomes
    }
}
