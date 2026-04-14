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
    /// Each key is an ``EncoderName`` identifying a reduction encoder, and the value is the total number of probes that encoder generated across all cycles. Includes cache rejections that did not lead to a materialization.
    public var encoderProbes: [EncoderName: Int] = [:]

    /// Per-encoder counts of probes that were accepted (decoder produced a valid shrink) during the reduction phase.
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
    public var graphStats: ChoiceGraphStats?

    /// One-line summary of per-phase invocations and acceptances aggregated across all cycles.
    public var phaseSummary: String {
        ""
    }

    /// One-line summary of profiling data for the reduction planning decision tree.
    public var profilingSummary: String {
        let phaseLabel = phaseSummary.isEmpty ? "" : " \(phaseSummary)"
        let graphLabel: String
        if let graphStats {
            graphLabel = " graph=\(graphStats.nodeCount)n/\(graphStats.fullGraphRebuilds)r/\(graphStats.dynamicRegionRebuilds)dr"
        } else {
            graphLabel = ""
        }
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
        return "cycles=\(cycles) invocations=\(propertyInvocations) materializations=\(totalMaterializations) probes=\(coverageInvocations)cov/\(randomSamplingInvocations)rand\(graphLabel)\(encoderLabel)\(phaseLabel)"
    }

    /// Populates reduction statistics from a ``ReductionStats`` value.
    public mutating func applyReductionStats(_ stats: ReductionStats) {
        encoderProbes = stats.encoderProbes
        encoderProbesAccepted = stats.encoderProbesAccepted
        encoderProbesRejectedByCache = stats.encoderProbesRejectedByCache
        encoderProbesRejectedByDecoder = stats.encoderProbesRejectedByDecoder
        totalMaterializations = stats.totalMaterializations
        cycles = stats.cycles
        filterObservations = stats.filterObservations
        graphStats = stats.graphStats
    }
}
