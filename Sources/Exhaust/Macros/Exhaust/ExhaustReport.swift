import ExhaustCore

/// Captures run statistics from a single `#exhaust` invocation.
///
/// Delivered via the ``PropertySettings/onReport(_:)`` setting. Contains phase timing, invocation counts, per-encoder probe breakdown, per-fingerprint filter validity observations, and profiling data for the reduction planning decision tree.
public struct ExhaustReport: Sendable {
    /// The PRNG seed used for random sampling, if any.
    public var seed: UInt64?

    /// The encoded replay string for reproducing this failure (for example, `"1A-7"` or `"U3"`), or `nil` if the test passed.
    public var replaySeed: String?

    /// The rendered failure message from the Bool pipeline, stored for `__exhaustExpect` to emit.
    package var renderedFailure: String?

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

    /// Records the three phase buckets for a concurrent runner whose reduction probes flow through the same shared invocation counter as the phase that discovered the failure.
    ///
    /// The concurrent runners drive a single property closure across coverage, sampling, and reduction, so every reduction probe lands inside whichever phase bucket was open when reduction ran. Left uncorrected, that probe would be counted twice — once in the enclosing phase and once in reduction. This peels reduction back out of its enclosing bucket so the three buckets stay disjoint and sum to `totalInvocations`.
    ///
    /// - Parameters:
    ///   - totalInvocations: The shared counter's final value, the sum the three buckets must reproduce.
    ///   - coverageThroughReduction: The counter value captured at the end of the coverage phase. It already includes coverage-phase reduction when the failure was found during coverage; it equals `totalInvocations` for a runner that returns immediately on a coverage failure.
    ///   - reduction: Reduction probe count, measured by snapshotting the shared counter around the reduce call.
    ///   - discoveredDuringCoverage: Whether the failure (and therefore the reduction) occurred in the coverage phase. Selects which enclosing bucket the reduction is peeled from: coverage when `true`, sampling otherwise.
    package mutating func setConcurrentInvocations(
        totalInvocations: Int,
        coverageThroughReduction: Int,
        reduction: Int,
        discoveredDuringCoverage: Bool
    ) {
        let coverage = discoveredDuringCoverage ? coverageThroughReduction - reduction : coverageThroughReduction
        let sampling = totalInvocations - coverageThroughReduction - (discoveredDuringCoverage ? 0 : reduction)
        setInvocations(coverage: coverage, randomSampling: sampling, reduction: reduction)
    }

    /// Total materialization attempts (decoder invocations) during the reduction phase.
    public var totalMaterializations: Int = 0

    /// Per-encoder probe counts from the reduction phase.
    ///
    /// Each key is an ``EncoderName`` identifying a reduction encoder, and the value is the total number of probes that encoder generated across all cycles. Includes cache rejections that did not lead to a materialization.
    public var encoderProbes: [EncoderName: Int] = [:]

    /// Per-encoder counts of probes that were accepted (decoder produced a valid reduction) during the reduction phase.
    public var encoderProbesAccepted: [EncoderName: Int] = [:]

    /// Per-encoder counts of probes that were rejected by the scope rejection cache without materializing.
    public var encoderProbesRejectedByCache: [EncoderName: Int] = [:]

    /// Per-encoder counts of probes that were materialized but rejected by the decoder (failed shortlex check, range violation, or property still passes).
    public var encoderProbesRejectedByDecoder: [EncoderName: Int] = [:]

    /// Total reduction cycles completed.
    public var cycles: Int = 0

    /// Per-fingerprint filter predicate observations accumulated during reduction.
    public var filterObservations: [UInt64: FilterObservation] = [:]

    // MARK: - Graph Reducer

    /// Graph structure and lifecycle statistics from the reduction phase. `nil` when the reduction phase did not run.
    package var graphStats: ChoiceGraphStats?

    /// Per-step aggregate wall-time from the reduction state machine. `nil` when the reduction phase did not run or stats collection was disabled.
    package var stepTimings: ReductionStats.StepTimings?

    /// True when the reduction phase was terminated early by the wall-clock deadline. The counterexample may not be fully reduced.
    package var reductionWasCapped: Bool = false

    /// OpenPBTStats records captured during the run.
    ///
    /// Empty when ``PropertySettings/collectOpenPBTStats`` is disabled or the run produced no records. For failing runs, the second-to-last element is the failing example and the last element is the reduced counterexample.
    package var openPBTStatsLines: [OpenPBTStatsLine] = []

    /// Summarizes profiling data as a single line.
    public var profilingSummary: String {
        let graphLabel = graphStats.map {
            " graph=\($0.nodeCount)n/\($0.fullGraphRebuilds)r/\($0.dynamicRegionRebuilds)dr"
        } ?? ""
        let activeEncoders = encoderProbes.keys.sorted { encoderProbes[$0, default: 0] > encoderProbes[$1, default: 0] }
        let encoderLabel = activeEncoders.isEmpty ? "" : " " + activeEncoders.map { name in
            let emitted = encoderProbes[name] ?? 0
            let accepted = encoderProbesAccepted[name] ?? 0
            let cacheRej = encoderProbesRejectedByCache[name] ?? 0
            let decRej = encoderProbesRejectedByDecoder[name] ?? 0
            let invocations = emitted - cacheRej - decRej
            let pct = invocations > 0 ? accepted * 100 / invocations : 0
            return "\(name.rawValue)=i\(invocations)/a\(accepted)/c\(cacheRej)/d\(decRej)/\(pct)%"
        }.joined(separator: " ")
        let timingLabel: String
        if let timings = stepTimings {
            let dispMs = Double(timings.dispatch) / 1_000_000
            let srcMs = Double(timings.buildSources) / 1_000_000
            let encMs = Double(timings.encode) / 1_000_000
            let decMs = Double(timings.decode) / 1_000_000
            let rebMs = Double(timings.rebuild) / 1_000_000
            let ccMs = Double(timings.convergenceConfirmation) / 1_000_000
            let rlxMs = Double(timings.relaxRound) / 1_000_000
            let reordMs = Double(timings.reorder) / 1_000_000
            let totalMs = srcMs + dispMs + encMs + decMs + rebMs + ccMs + rlxMs + reordMs
            timingLabel = " timing=\(String(format: "%.2f", totalMs))ms(src=\(String(format: "%.2f", srcMs))/disp=\(String(format: "%.2f", dispMs))/enc=\(String(format: "%.2f", encMs))/dec=\(String(format: "%.2f", decMs))/reb=\(String(format: "%.2f", rebMs))/cc=\(String(format: "%.2f", ccMs))/rlx=\(String(format: "%.2f", rlxMs))/reord=\(String(format: "%.2f", reordMs)))"
        } else {
            timingLabel = ""
        }
        return "cycles=\(cycles) invocations=\(coverageInvocations)cov/\(randomSamplingInvocations)gen/\(reductionInvocations)red materializations=\(totalMaterializations)\(graphLabel)\(encoderLabel)\(timingLabel)"
    }

    /// Populates reduction statistics from a ``ReductionStats`` value.
    package mutating func applyReductionStats(_ stats: ReductionStats) {
        encoderProbes.merge(stats.encoderProbes) { existing, new in existing + new }
        encoderProbesAccepted.merge(stats.encoderProbesAccepted) { existing, new in existing + new }
        encoderProbesRejectedByCache.merge(stats.encoderProbesRejectedByCache) { existing, new in existing + new }
        encoderProbesRejectedByDecoder.merge(stats.encoderProbesRejectedByDecoder) { existing, new in existing + new }
        totalMaterializations += stats.totalMaterializations
        cycles += stats.cycles
        filterObservations.merge(stats.filterObservations) { _, new in new }
        graphStats = stats.graphStats
        stepTimings = stats.stepTimings
        reductionWasCapped = reductionWasCapped || stats.reductionWasCapped
    }
}
