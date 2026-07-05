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

    /// Floor-motion events where a graph rebuild happened between the old and new convergence record. The floor shifted because the sequence structure changed (deletion, bind reshape), not because a partner coordinate's value moved.
    package var structuralFloorMotionEvents: Int

    /// Floor-motion events within the same rebuild generation. The floor shifted because a partner coordinate's value movement changed the property boundary for this leaf. This is the observable signal for inter-coordinate value coupling (R8).
    package var valueFloorMotionEvents: Int

    // MARK: - Coupling Diagnostics

    /// Node IDs that experienced value floor motion at least once during this run.
    package var valueFloorMotionNodeIDs: Set<Int> = []

    /// Node IDs that were part of an accepted redistribution pair (source or sink) at least once during this run.
    package var redistributionAcceptanceNodeIDs: Set<Int> = []

    /// Measured coupling edges. Each entry records that `motionNodeID`'s convergence floor shifted after `changedNodeID`'s value was accepted. Multiple observations of the same edge increment `count`.
    package var couplingEdges: [CouplingEdge: Int] = [:]

    /// Distribution of partner counts per value floor-motion event. Key is the number of distinct nodes that changed between the shifting node's previous and current convergence. A count of 1 means the floor shift is attributable to a single partner (pairwise). Counts of 2+ mean multiple partners changed and the coupling may be k-ary.
    package var floorMotionPartnerCounts: [Int: Int] = [:]

    /// True when the reduction phase was terminated early by the wall-clock deadline.
    package var reductionWasCapped: Bool = false

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
        reductionWasCapped = reductionWasCapped || other.reductionWasCapped
        for (key, value) in other.filterObservations {
            filterObservations[key, default: FilterObservation()].merge(value)
        }
        graphStats.merge(other.graphStats)
        stepTimings.merge(other.stepTimings)
    }
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
