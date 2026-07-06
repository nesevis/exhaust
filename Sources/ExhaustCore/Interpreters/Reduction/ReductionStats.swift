/// Statistics collected from a single reduction run.
///
/// Captures per-encoder probe counts, materialization attempts, per-fingerprint filter validity observations, and profiling data for the reduction planning decision tree. Accumulated monotonically by ``ReductionMachine`` during reduction and extracted at the end of the pipeline.
public struct ReductionStats: Sendable {
    /// Per-encoder probe counts accumulated across all cycles. Total probes emitted by each encoder, including those that hit the reject cache.
    package var encoderProbes: [EncoderName: Int]

    /// Per-encoder probe counts that were accepted (the decoder produced a valid reduction).
    package var encoderProbesAccepted: [EncoderName: Int]

    /// Per-encoder probe counts that hit the reject cache before decoding (no materialization).
    package var encoderProbesRejectedByCache: [EncoderName: Int]

    /// Per-encoder probe counts that were materialized but rejected by the decoder (failed shortlex check, filter rejection, range violation, decode error, or property still passes). Each such probe consumes one materialization without a property invocation.
    package var encoderProbesRejectedByDecoder: [EncoderName: Int]

    /// Total materialization attempts (decoder invocations) during reduction.
    package var totalMaterializations: Int

    /// Total reduction cycles completed.
    package var cycles: Int

    /// Floor-motion events where a graph rebuild happened between the old and new convergence record. The floor shifted because the sequence structure changed (deletion, bind reshape), not because a partner coordinate's value moved. Populated only when `ReductionMachine`'s maintainer-set `collectDiagnostics` flag is enabled.
    package var structuralFloorMotionEvents: Int

    /// Floor-motion events within the same rebuild generation. The floor shifted because a partner coordinate's value movement changed the property boundary for this leaf. This is the observable signal for inter-coordinate value coupling (R8). Populated only when `ReductionMachine`'s maintainer-set `collectDiagnostics` flag is enabled.
    package var valueFloorMotionEvents: Int

    // MARK: - Coupling Diagnostics

    /// Node IDs that experienced value floor motion at least once during this run. Populated only when `ReductionMachine`'s maintainer-set `collectDiagnostics` flag is enabled.
    package var valueFloorMotionNodeIDs: Set<Int> = []

    /// Node IDs that were part of an accepted redistribution pair (source or sink) at least once during this run. Populated only when `ReductionMachine`'s maintainer-set `collectDiagnostics` flag is enabled.
    package var redistributionAcceptanceNodeIDs: Set<Int> = []

    /// Measured coupling edges. Each entry records that `motionNodeID`'s convergence floor shifted after `changedNodeID`'s value was accepted. Multiple observations of the same edge increment `count`. Populated only when `ReductionMachine`'s maintainer-set `collectDiagnostics` flag is enabled.
    package var couplingEdges: [CouplingEdge: Int] = [:]

    /// Distribution of partner counts per value floor-motion event. Key is the number of distinct nodes that changed between the shifting node's previous and current convergence. A count of 1 means the floor shift is attributable to a single partner (pairwise). Counts of 2+ mean multiple partners changed and the coupling may be k-ary. Populated only when `ReductionMachine`'s maintainer-set `collectDiagnostics` flag is enabled.
    package var floorMotionPartnerCounts: [Int: Int] = [:]

    // MARK: - Dispatch Log

    /// One record per completed encoder pass, in dispatch order. Populated only when ``ReductionMachine``'s maintainer-set `collectDiagnostics` flag is enabled; empty in all normal runs, including stats-collecting ones. The within-cycle ordering (via ``DispatchRecord/cycle`` and ``DispatchRecord/passIndex``) is what the indexability analysis conditions on, so the log must not be reordered.
    package var dispatchLog: [DispatchRecord] = []

    /// True when the reduction phase was terminated early by the wall-clock deadline.
    package var reductionWasCapped: Bool = false

    // MARK: - Stall Diagnostic

    /// Leaves that terminated with a convergence record at their current value while short of their reduction target. Nonzero counts are normal for successful reductions (a property demanding nonzero values leaves surviving leaves short of their targets); the silent-stall signal is a nonzero count with ``anyAcceptanceEverOccurred`` false.
    package var stalledLeafCount: Int = 0

    /// Sum of the pattern-space gaps between each stalled leaf's terminal value and its reduction target. A magnitude for the stall warning; meaningful only relative to the workload's value ranges.
    package var stalledLeafResidualDistance: Double = 0

    /// True when any pass in the run accepted at least one probe. False means the reducer could not improve the input even once — combined with a nonzero ``stalledLeafCount``, the counterexample likely sits far from minimal behind a coupling the encoder roster cannot cross.
    package var anyAcceptanceEverOccurred: Bool = false

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
        structuralFloorMotionEvents = 0
        valueFloorMotionEvents = 0
        graphStats = ChoiceGraphStats()
    }

    /// Merges another stats value into this one by summing counters and taking the latest graph stats.
    package mutating func merge(_ other: ReductionStats) {
        for (key, value) in other.encoderProbes {
            encoderProbes[key, default: 0] += value
        }
        for (key, value) in other.encoderProbesAccepted {
            encoderProbesAccepted[key, default: 0] += value
        }
        for (key, value) in other.encoderProbesRejectedByCache {
            encoderProbesRejectedByCache[key, default: 0] += value
        }
        for (key, value) in other.encoderProbesRejectedByDecoder {
            encoderProbesRejectedByDecoder[key, default: 0] += value
        }
        totalMaterializations += other.totalMaterializations
        cycles += other.cycles
        structuralFloorMotionEvents += other.structuralFloorMotionEvents
        valueFloorMotionEvents += other.valueFloorMotionEvents
        valueFloorMotionNodeIDs.formUnion(other.valueFloorMotionNodeIDs)
        redistributionAcceptanceNodeIDs.formUnion(other.redistributionAcceptanceNodeIDs)
        for (edge, count) in other.couplingEdges {
            couplingEdges[edge, default: 0] += count
        }
        for (partnerCount, events) in other.floorMotionPartnerCounts {
            floorMotionPartnerCounts[partnerCount, default: 0] += events
        }
        dispatchLog.append(contentsOf: other.dispatchLog)
        reductionWasCapped = reductionWasCapped || other.reductionWasCapped
        stalledLeafCount += other.stalledLeafCount
        stalledLeafResidualDistance += other.stalledLeafResidualDistance
        anyAcceptanceEverOccurred = anyAcceptanceEverOccurred || other.anyAcceptanceEverOccurred
        for (key, value) in other.filterObservations {
            filterObservations[key, default: FilterObservation()].merge(value)
        }
        graphStats.merge(other.graphStats)
        stepTimings.merge(other.stepTimings)
    }
}

// MARK: - Dispatch Record

/// One completed encoder pass, as seen by the scheduler.
///
/// This is the raw material for the scheduling-cluster analyses: reservation values need the per-encoder distribution of improvement given acceptance against probes spent (R17), the indexability check conditions an encoder's acceptance rate on whether an earlier pass in the same cycle accepted (R14), and the potential-shaping pre-filter needs whole trajectories (R16). Relax-round exploitation passes and the post-loop reorder pass are included; a rolled-back relax round's records describe the discarded excursion trajectory.
package struct DispatchRecord: Sendable {
    /// The reduction cycle this pass ran in.
    package let cycle: Int

    /// Monotonic pass counter, unique within a run. Orders passes within a cycle.
    package let passIndex: Int

    /// The encoder that ran the pass.
    package let encoderName: EncoderName

    /// Probes emitted, including reject-cache hits.
    package let probeCount: Int

    /// Probes accepted by the decoder.
    package let acceptCount: Int

    /// Probes short-circuited by the reject cache without a materialization.
    package let cacheHitCount: Int

    /// Probes materialized but rejected by the decoder.
    package let decoderRejectCount: Int

    /// Sequence length before the pass minus length after. Positive when the pass shrank the sequence.
    package let sequenceLengthDelta: Int

    /// Total distance-to-reduction-target before the pass minus after. Positive when the pass moved values toward their targets. Distance is summed over value entries as the absolute pattern-space gap to each entry's reduction target, so the scalar is meaningful for signed encodings. Floating point because full-range leaves have distances near 2^63 and sums must neither overflow nor saturate; the lost low-bit precision at that magnitude is irrelevant for scheduling diagnostics.
    package let targetDistanceDelta: Double

    /// The dispatched bind's fingerprint, for bound-value composed passes; nil for every other encoder. Fingerprints are source-location-stable, so equal values across records (and across seeds) identify the same bind site — the composed-spend analysis groups on this to distinguish many binds each paying once from few binds re-paying.
    package let boundValueFingerprint: UInt64?

    /// Upstream probes that produced a valid lift, for composed passes; nil otherwise. Every emitted probe is a wrapped downstream probe, so ``probeCount`` measures the downstream side of the composition's spend while this measures the upstream side, where each lift is one generator materialization plus a downstream search cold-start.
    package let composedUpstreamLifts: Int?

    /// The dispatched bind's classification at pass-report time, for composed passes; nil otherwise. Dispatch currently requires the identical/both verdict, so this column is a sanity check that the gate's dispatch rule held rather than a source of variation.
    package let bindClassification: BindClassification?
}

// MARK: - Step Timings

public extension ReductionStats {
    /// Aggregate wall-time spent in each ``ReductionMachine`` step category.
    ///
    /// Times are in nanoseconds. Populated by the driver loop that calls ``ReductionMachine/next()`` and measures the elapsed time per step.
    struct StepTimings: Sendable {
        public var dispatch: UInt64 = 0
        public var buildSources: UInt64 = 0
        public var encode: UInt64 = 0
        public var decode: UInt64 = 0
        public var rebuild: UInt64 = 0
        public var convergenceConfirmation: UInt64 = 0
        public var relaxRound: UInt64 = 0
        public var relationPass: UInt64 = 0
        public var reorder: UInt64 = 0

        public var dispatchCount: Int = 0
        public var encodeCount: Int = 0
        public var decodeCount: Int = 0
        public var rebuildCount: Int = 0
        public var rebuildGraphNanoseconds: UInt64 = 0
        public var rebuildSourceNanoseconds: UInt64 = 0

        package init() {}

        /// Merges another timings value by summing all counters and durations.
        package mutating func merge(_ other: StepTimings) {
            dispatch += other.dispatch
            buildSources += other.buildSources
            encode += other.encode
            decode += other.decode
            rebuild += other.rebuild
            convergenceConfirmation += other.convergenceConfirmation
            relaxRound += other.relaxRound
            relationPass += other.relationPass
            reorder += other.reorder
            dispatchCount += other.dispatchCount
            encodeCount += other.encodeCount
            decodeCount += other.decodeCount
            rebuildCount += other.rebuildCount
            rebuildGraphNanoseconds += other.rebuildGraphNanoseconds
            rebuildSourceNanoseconds += other.rebuildSourceNanoseconds
        }

        /// Records elapsed time for a step transition.
        package mutating func record(_ transition: ReductionMachine.Transition, elapsed: UInt64) {
            switch transition {
                case .dispatched:
                    dispatch += elapsed
                    dispatchCount += 1
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
                case .relationPassCompleted:
                    relationPass += elapsed
                case .reorderCompleted:
                    reorder += elapsed
                case .sourcesBuilt:
                    buildSources += elapsed
                case .cycleStarted, .cycleEnded, .deferralReleased, .terminated:
                    break
            }
        }
    }
}

// MARK: - Coupling Edge

/// A directed edge in the measured coupling graph: `motionNodeID`'s convergence floor shifted after `changedNodeID`'s value was accepted.
public struct CouplingEdge: Hashable, Sendable {
    /// The node whose convergence floor shifted.
    public let motionNodeID: Int

    /// The node whose value change preceded the floor shift.
    public let changedNodeID: Int
}
