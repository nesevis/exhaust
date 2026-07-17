import ExhaustCore

/// Captures run statistics from a single `#exhaust` invocation.
///
/// Delivered via the ``PropertySettings/onReport(_:)`` setting. Contains phase timing, invocation counts, per-encoder probe breakdown, per-fingerprint filter validity observations, and profiling data for the reduction planning decision tree.
public struct ExhaustReport: Sendable {
    /// The PRNG seed for this run, when one was supplied by the caller via `.replay` or resolved from a regression trait. `nil` for non-replay runs and for screening-only results.
    public var seed: UInt64?

    /// The encoded replay string for reproducing this failure (for example, `"1A-7"` or `"U3"`), or `nil` if the test passed.
    public var replaySeed: String?

    /// The rendered failure message from the Bool pipeline, stored for `__exhaustExpect` to emit.
    package var renderedFailure: String?

    /// Time spent in the screening phase, in milliseconds.
    public var screeningMilliseconds: Double = 0

    /// Time spent in the random generation phase, in milliseconds.
    public var generationMilliseconds: Double = 0

    /// Time spent in the reduction phase, in milliseconds.
    public var reductionMilliseconds: Double = 0

    /// Time spent in reflection (only populated for the `.reflecting` path), in milliseconds.
    public var reflectionMilliseconds: Double = 0

    /// Total wall-clock time, in milliseconds.
    public var totalMilliseconds: Double = 0

    /// Total property invocations across all phases, including the final source-located diagnostic rerun when one executes.
    public var propertyInvocations: Int = 0

    /// Property invocations during the screening phase.
    public var screeningInvocations: Int = 0

    /// Counts covering-array rows considered as screening candidates.
    public var screeningRows: Int = 0

    /// Counts screening rows rejected before property invocation.
    public var screeningRejectedRows: Int = 0

    /// Property invocations during the random sampling phase.
    public var randomSamplingInvocations: Int = 0

    /// Property invocations during the reduction phase (counted by the wrapping closure).
    public var reductionInvocations: Int = 0

    /// Property invocations used to reproduce a final source-located diagnostic after reduction.
    public var diagnosticInvocations: Int = 0

    /// Property invocations that were skipped by throwing ``PropertySkip`` (or `XCTSkip`).
    ///
    /// Skipped invocations count toward ``propertyInvocations`` but assert nothing. A run whose every invocation was skipped fails as pointless.
    public var skippedInvocations: Int = 0

    /// Whether the sampling phase ended before its budget because a `ReflectiveGenerator.unique(fileID:line:column:)` site exhausted its retry budget.
    ///
    /// When true, ``randomSamplingInvocations`` is smaller than the configured sampling budget: the deduplicated domain ran dry and the remaining iterations never ran.
    public var runTruncatedByUniqueExhaustion = false

    /// Advisory message for a unique-exhaustion truncation, stashed so the `#expect` wrappers can re-report it outside their known-issue scope.
    package var uniqueExhaustionWarning: String?

    /// Whether a phase reported a generation error. Suppresses the pointless-run error, which would otherwise stack a second issue on the same root cause.
    package var generationErrorOccurred = false

    /// Failure message for a passing run that asserted nothing (a pointless run). Stashed so the `#expect` wrappers can re-report it outside their known-issue scope, where the pipeline's own issue is swallowed.
    package var pointlessRunFailure: String?

    /// Advisory message for a run that skipped nearly every invocation, stashed so the `#expect` wrappers can re-report it outside their known-issue scope.
    package var skipRateWarning: String?

    /// Sets the per-phase property invocation counts and derives the total.
    public mutating func setInvocations(
        screening: Int,
        randomSampling: Int,
        reduction: Int
    ) {
        screeningInvocations = screening
        randomSamplingInvocations = randomSampling
        reductionInvocations = reduction
        diagnosticInvocations = 0
        propertyInvocations = screening + randomSampling + reduction
    }

    /// Records one source-located diagnostic rerun after the pipeline has produced its report.
    package mutating func recordDiagnosticInvocation() {
        diagnosticInvocations += 1
        propertyInvocations += 1
    }

    /// Applies screening row and invocation counts without changing later phase buckets.
    package mutating func applyScreeningSummary(_ summary: ScreeningRunner.Summary) {
        screeningRows = summary.rowAttempts
        screeningRejectedRows = summary.rejectedRows
        screeningInvocations = summary.propertyInvocations
        propertyInvocations = screeningInvocations
            + randomSamplingInvocations
            + reductionInvocations
            + diagnosticInvocations
    }

    /// Applies sampling and reduction counts while preserving the screening summary already recorded for the run.
    package mutating func applyPostScreeningInvocations(
        randomSampling: Int,
        reduction: Int
    ) {
        randomSamplingInvocations = randomSampling
        reductionInvocations = reduction
        diagnosticInvocations = 0
        propertyInvocations = screeningInvocations + randomSampling + reduction
    }

    /// Records the three phase buckets for a concurrent runner whose reduction probes flow through the same shared invocation counter as the phase that discovered the failure.
    ///
    /// The concurrent runners drive a single property closure across screening, sampling, and reduction, so every reduction probe lands inside whichever phase bucket was open when reduction ran. Left uncorrected, that probe would be counted twice — once in the enclosing phase and once in reduction. This peels reduction back out of its enclosing bucket so the three buckets stay disjoint and sum to `totalInvocations`.
    ///
    /// - Parameters:
    ///   - totalInvocations: The shared counter's final value, the sum the three buckets must reproduce.
    ///   - screeningThroughReduction: The counter value captured at the end of the screening phase. It already includes screening-phase reduction when the failure was found during screening; it equals `totalInvocations` for a runner that returns immediately on a screening failure.
    ///   - reduction: Reduction probe count, measured by snapshotting the shared counter around the reduce call.
    ///   - discoveredDuringScreening: Whether the failure (and therefore the reduction) occurred in the screening phase. Selects which enclosing bucket the reduction is peeled from: screening when `true`, sampling otherwise.
    package mutating func setConcurrentInvocations(
        totalInvocations: Int,
        screeningThroughReduction: Int,
        reduction: Int,
        discoveredDuringScreening: Bool
    ) {
        let screening = discoveredDuringScreening ? screeningThroughReduction - reduction : screeningThroughReduction
        let sampling = totalInvocations - screeningThroughReduction - (discoveredDuringScreening ? 0 : reduction)
        setInvocations(screening: screening, randomSampling: sampling, reduction: reduction)
    }

    /// Projects invocation counts from a ``RunLedger``, replacing the piecemeal setter methods.
    ///
    /// Each phase bucket reads directly from the ledger's phase counts, so reduction events recorded under their own phase never leak into the screening or sampling bucket. This eliminates the peel-back arithmetic in ``setConcurrentInvocations(totalInvocations:screeningThroughReduction:reduction:discoveredDuringScreening:)``.
    package mutating func applyLedger(_ ledger: RunLedger) {
        screeningInvocations = ledger.invocations(.screening)
        randomSamplingInvocations = ledger.invocations(.sampling)
        reductionInvocations = ledger.invocations(.reduction)
        diagnosticInvocations = ledger.invocations(.diagnostic)
        skippedInvocations = ledger.totalSkips
        propertyInvocations = screeningInvocations
            + randomSamplingInvocations
            + reductionInvocations
            + diagnosticInvocations
    }

    /// Total materialization attempts (decoder invocations) during the reduction phase.
    public var totalMaterializations: Int = 0

    /// Counts reduction proposals opened by encoder passes and structural relax rounds.
    public var reductionProbes: Int = 0

    /// Counts reduction proposals admitted after the property failed. Structural relax proposals count as admitted even if the later relax round rolls back.
    public var reductionProbesAccepted: Int = 0

    /// Counts reduction proposals rejected by the cache before materialization.
    public var reductionProbesRejectedByCache: Int = 0

    /// Counts reduction proposals rejected during materialization before the property ran.
    public var reductionProbesRejectedDuringMaterialization: Int = 0

    /// Counts reduction proposals whose materialized value satisfied the property.
    public var reductionProbesWherePropertyPassed: Int = 0

    /// Counts reduction proposals whose materialized value falsified the property. This includes admitted proposals and proposals rejected by the subsequent tree-building materialization or ordering check.
    public var reductionProbesWherePropertyFailed: Int = 0

    /// Per-encoder probe counts from the reduction phase.
    ///
    /// Each key is an `EncoderName` identifying a reduction encoder, and the value is the total number of probes that encoder generated across all cycles. Includes cache rejections that did not lead to a materialization.
    public var encoderProbes: [EncoderName: Int] = [:]

    /// Per-encoder counts of probes that were accepted (decoder produced a valid reduction) during the reduction phase.
    public var encoderProbesAccepted: [EncoderName: Int] = [:]

    /// Per-encoder counts of probes that were rejected by the scope rejection cache without materializing.
    public var encoderProbesRejectedByCache: [EncoderName: Int] = [:]

    /// Per-encoder counts of probes rejected during materialization before the property ran. Structural relax proposals have no encoder and appear only in the run-wide reduction counts.
    public var encoderProbesRejectedDuringMaterialization: [EncoderName: Int] = [:]

    /// Per-encoder counts of probes whose materialized value satisfied the property. Structural relax proposals have no encoder and appear only in the run-wide reduction counts.
    public var encoderProbesWherePropertyPassed: [EncoderName: Int] = [:]

    /// Per-encoder counts of probes whose materialized value falsified the property. Structural relax proposals have no encoder and appear only in the run-wide reduction counts.
    public var encoderProbesWherePropertyFailed: [EncoderName: Int] = [:]

    /// Combines per-encoder materialization rejection, property success, and property failure that was not admitted. Use the separated per-encoder counts when the rejection stage matters.
    public var encoderProbesRejectedByDecoder: [EncoderName: Int] = [:]

    /// Total reduction cycles completed.
    public var cycles: Int = 0

    /// Floor-motion events caused by structural changes (graph rebuild between old and new record).
    public var structuralFloorMotionEvents: Int = 0

    /// Floor-motion events caused by value coupling (same rebuild generation, partner coordinate shifted the boundary).
    public var valueFloorMotionEvents: Int = 0

    /// Node IDs that experienced value floor motion during this run.
    public var valueFloorMotionNodeIDs: Set<Int> = []

    /// Node IDs that were part of a redistribution scope when redistribution accepted during this run.
    public var redistributionAcceptanceNodeIDs: Set<Int> = []

    /// Measured coupling edges from this run. Each edge records that one node's floor shifted after another node's value changed.
    public var couplingEdges: [CouplingEdge: Int] = [:]

    /// Distribution of partner counts per value floor-motion event.
    public var floorMotionPartnerCounts: [Int: Int] = [:]

    /// Per-fingerprint filter predicate observations accumulated during reduction.
    public var filterObservations: [UInt64: FilterObservation] = [:]

    /// Leaves that ended reduction converged at their current value while short of their reduction target. Nonzero counts are normal for successful reductions; see ``reductionStalled`` for the warning condition.
    public var stalledLeafCount: Int = 0

    /// Sum of the gaps between each stalled leaf's terminal value and its reduction target, in bit-pattern space.
    public var stalledLeafResidualDistance: Double = 0

    /// True when the reducer accepted at least one improvement during reduction.
    public var anyAcceptanceEverOccurred: Bool = false

    /// True when reduction could not improve the counterexample even once while leaves sit short of their reduction targets. The counterexample may be far from minimal — typically the failing values are linked by a relationship (for example `x == 2 * y + 1`) that no single-value change can preserve, so every reduction attempt un-fails the property. Deadline-capped runs are excluded: they report the time limit instead, because their lack of progress is explained by the budget rather than by the landscape.
    public var reductionStalled: Bool {
        stalledLeafCount > 0 && anyAcceptanceEverOccurred == false && reductionWasCapped == false
    }

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
            let accepted = encoderProbesAccepted[name] ?? 0
            let cacheRejections = encoderProbesRejectedByCache[name] ?? 0
            let decoderRejections = encoderProbesRejectedByDecoder[name] ?? 0
            let invocations = (encoderProbesWherePropertyPassed[name] ?? 0)
                + (encoderProbesWherePropertyFailed[name] ?? 0)
            let acceptancePercentage = invocations > 0 ? accepted * 100 / invocations : 0
            return "\(name.rawValue)=i\(invocations)/a\(accepted)/c\(cacheRejections)/d\(decoderRejections)/\(acceptancePercentage)%"
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
        return "cycles=\(cycles) invocations=\(screeningInvocations)scr/\(randomSamplingInvocations)gen/\(reductionInvocations)red/\(diagnosticInvocations)diag materializations=\(totalMaterializations)\(graphLabel)\(encoderLabel)\(timingLabel)"
    }

    /// Populates reduction statistics from a ``ReductionStats`` value. Each call overwrites the previous stats; the reducer runs a single reduction pass per report, so there is nothing to accumulate.
    package mutating func applyReductionStats(_ stats: ReductionStats) {
        let counts = stats.encoderCounts
        encoderProbes = counts.mapValues(\.emitted)
        encoderProbesAccepted = counts.mapValues(\.accepted)
        encoderProbesRejectedByCache = counts.mapValues(\.rejectedByCache)
        encoderProbesRejectedDuringMaterialization = counts.mapValues(\.rejectedDuringMaterialization)
        encoderProbesWherePropertyPassed = counts.mapValues(\.propertyPassed)
        encoderProbesWherePropertyFailed = counts.mapValues(\.propertyFailed)
        encoderProbesRejectedByDecoder = counts.mapValues(\.decoderRejections)
        reductionProbes = stats.reductionProbes
        reductionProbesAccepted = stats.reductionProbesAccepted
        reductionProbesRejectedByCache = stats.reductionProbesRejectedByCache
        reductionProbesRejectedDuringMaterialization = stats.reductionProbesRejectedDuringMaterialization
        reductionProbesWherePropertyPassed = stats.reductionProbesWherePropertyPassed
        reductionProbesWherePropertyFailed = stats.reductionProbesWherePropertyFailed
        totalMaterializations = stats.totalMaterializations
        cycles = stats.cycles
        structuralFloorMotionEvents = stats.structuralFloorMotionEvents
        valueFloorMotionEvents = stats.valueFloorMotionEvents
        valueFloorMotionNodeIDs = stats.valueFloorMotionNodeIDs
        redistributionAcceptanceNodeIDs = stats.redistributionAcceptanceNodeIDs
        couplingEdges = stats.couplingEdges
        floorMotionPartnerCounts = stats.floorMotionPartnerCounts
        filterObservations = stats.filterObservations
        stalledLeafCount = stats.stalledLeafCount
        stalledLeafResidualDistance = stats.stalledLeafResidualDistance
        anyAcceptanceEverOccurred = stats.anyAcceptanceEverOccurred
        graphStats = stats.graphStats
        stepTimings = stats.stepTimings
        reductionWasCapped = stats.reductionWasCapped
    }
}
