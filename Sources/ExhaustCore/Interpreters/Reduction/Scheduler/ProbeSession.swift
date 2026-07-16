//
//  ProbeSession.swift
//  Exhaust
//

// MARK: - Probe Session State

/// The mutable surface a ``ProbeSession`` needs from its host.
///
/// ``ReductionMachine`` conforms with zero adapter code. Test harnesses can provide a lightweight stub that tracks just sequence, tree, output, and graph.
protocol ProbeSessionState {
    var sequence: ChoiceSequence { get set }
    var tree: ChoiceTree { get set }
    var output: Any { get set }
    var graph: ChoiceGraph { get set }
    var gen: AnyGenerator { get }
    var property: (Any) -> Bool { get }
    var rejectCache: Set<UInt64> { get set }
    var collectStats: Bool { get }
    var isInstrumented: Bool { get }
}

// MARK: - Probe Session

/// Drives the encode-decode loop for a single encoder pass.
///
/// Constructed by the machine when dispatch selects an encoder. Advanced by ``step(state:)`` (one sub-phase per call) or ``runToCompletion(state:deadlineCheck:)`` (loops step internally). Produces a ``PassReport`` when finished via ``report()``.
struct ProbeSession {
    // MARK: - Phase

    /// Tracks the session's position within the encode-decode cycle.
    enum Phase {
        case encode
        case decode
        case finished
    }

    // MARK: - Step Result

    /// Describes what happened during one ``step(state:)`` call, returned to the machine for timing classification and control flow.
    enum StepResult {
        case encoded(encoder: EncoderName, cacheHit: Bool)
        case decoded(encoder: EncoderName, accepted: Bool)
        case finished
    }

    // MARK: - State

    private(set) var encoder: EncoderDispatch
    let transformation: GraphTransformation
    let boundValueFingerprint: UInt64?

    private var baseHash: UInt64
    private let hasBind: Bool

    private var candidateBuffer: ChoiceSequence
    private var lastProbeAccepted: Bool = false

    private var pendingMutation: ProjectedMutation?
    private var pendingProbeHash: UInt64 = 0
    private var pendingDecoderSelection: ChoiceGraphScheduler.DecoderSelection?

    private(set) var counts = ReductionProbeCounts()
    private(set) var anyAccepted: Bool = false
    private(set) var anyRequiresRebuild: Bool = false
    private(set) var latestTreeIsStripped: Bool = false
    private(set) var acceptedLeafNodeIDs: Set<Int> = []

    private(set) var phase: Phase = .encode

    // MARK: - Init

    init(
        encoder: EncoderDispatch,
        transformation: GraphTransformation,
        boundValueFingerprint: UInt64?,
        baseSequence: ChoiceSequence,
        hasBind: Bool
    ) {
        self.encoder = encoder
        self.transformation = transformation
        self.boundValueFingerprint = boundValueFingerprint
        baseHash = ZobristHash.hash(of: baseSequence)
        self.hasBind = hasBind
        candidateBuffer = baseSequence
    }

    // MARK: - Step

    /// Advances the session by one encode or decode sub-phase.
    mutating func step(state: inout some ProbeSessionState) throws -> StepResult {
        switch phase {
            case .encode:
                return stepEncode(state: &state)
            case .decode:
                return try stepDecode(state: &state)
            case .finished:
                return .finished
        }
    }

    // MARK: - Encode

    private mutating func stepEncode(state: inout some ProbeSessionState) -> StepResult {
        guard let mutation = encoder.nextProbe(
            into: &candidateBuffer,
            lastAccepted: lastProbeAccepted
        ) else {
            phase = .finished
            return .finished
        }

        counts.recordEmission()
        lastProbeAccepted = false

        let probeHash = ZobristHash.incrementalHash(
            baseHash: baseHash,
            baseSequence: state.sequence,
            probe: candidateBuffer
        )
        if state.rejectCache.contains(probeHash) {
            counts.recordCacheRejection()
            return .encoded(encoder: encoder.name, cacheHit: true)
        }

        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: encoder.isStateful,
            hasBind: hasBind
        )

        pendingMutation = mutation
        pendingProbeHash = probeHash
        pendingDecoderSelection = selection
        phase = .decode
        return .encoded(encoder: encoder.name, cacheHit: false)
    }

    // MARK: - Decode

    private mutating func stepDecode(state: inout some ProbeSessionState) throws -> StepResult {
        guard let mutation = pendingMutation,
              let selection = pendingDecoderSelection
        else {
            phase = .encode
            return .decoded(encoder: encoder.name, accepted: false)
        }

        let encoderName = encoder.name

        let decoder: SequenceDecoder = selection.preferExact
            ? .exact(materializePicks: selection.materializePicks)
            : .guided(fallbackTree: state.tree, materializePicks: selection.materializePicks)

        var filterObservations: [UInt64: FilterObservation] = [:]

        let outcome = try decoder.decodeAny(
            candidate: candidateBuffer,
            gen: state.gen,
            tree: state.tree,
            originalSequence: state.sequence,
            property: state.property,
            filterObservations: &filterObservations,
            precomputedHash: pendingProbeHash
        )
        counts.record(outcome)

        if let result = outcome.reduction {
            state.sequence = result.sequence
            state.tree = result.tree
            state.output = result.output
            baseHash = ZobristHash.hash(of: state.sequence)
            lastProbeAccepted = true
            anyAccepted = true

            if case let .leafValues(changes) = mutation {
                for change in changes {
                    acceptedLeafNodeIDs.insert(change.leafNodeID)
                }
            }

            latestTreeIsStripped = selection.materializePicks == false

            if encoder.isStateful {
                anyRequiresRebuild = true
            } else {
                let application = state.graph.apply(mutation)
                if application.requiresFullRebuild {
                    anyRequiresRebuild = true
                    phase = .finished
                    return .decoded(encoder: encoderName, accepted: true)
                }
            }

            if encoder.isStateful {
                encoder.refreshState(graph: state.graph, sequence: state.sequence)
            }

            phase = .encode
            return .decoded(encoder: encoderName, accepted: true)
        }

        state.rejectCache.insert(pendingProbeHash)
        if state.isInstrumented {
            ChoiceGraphScheduler.logReplacementProbeRejection(
                mutation: mutation,
                encoder: encoderName,
                graph: state.graph,
                baseSequenceCount: state.sequence.count,
                probeSequenceCount: candidateBuffer.count,
                probeHash: pendingProbeHash
            )
        }

        phase = .encode
        return .decoded(encoder: encoderName, accepted: false)
    }

    // MARK: - Report

    /// Produces the pass report by flushing partial convergence and snapshotting all counters.
    mutating func report() -> PassReport {
        encoder.flushPartialConvergence()

        return PassReport(
            encoderName: encoder.name,
            transformation: transformation,
            boundValueFingerprint: boundValueFingerprint,
            composedUpstreamLifts: encoder.composedUpstreamProbesUsed,
            counts: counts,
            anyAccepted: anyAccepted,
            anyRequiresRebuild: anyRequiresRebuild,
            latestTreeIsStripped: latestTreeIsStripped,
            convergenceRecords: encoder.convergenceRecords,
            hadReplacementShortlexRejection: encoder.hadReplacementShortlexRejection,
            acceptedLeafNodeIDs: acceptedLeafNodeIDs
        )
    }

    // MARK: - Run To Completion

    /// Runs the full encode-decode loop to completion, checking the optional deadline after each decode.
    mutating func runToCompletion(
        state: inout some ProbeSessionState,
        deadlineCheck: (() -> Bool)? = nil
    ) throws -> PassReport {
        while phase != .finished {
            let result = try step(state: &state)
            if case .decoded = result, deadlineCheck?() == true {
                phase = .finished
            }
        }
        return report()
    }
}

// MARK: - Pass Report

/// Summary of a completed encoder pass. The machine reads this to perform post-pass policy: gate recording, convergence harvest, scope rejection, stats accumulation.
struct PassReport {
    let encoderName: EncoderName
    let transformation: GraphTransformation
    let boundValueFingerprint: UInt64?

    /// Upstream probes that produced a valid lift, for composed passes; nil for every other encoder.
    let composedUpstreamLifts: Int?

    let counts: ReductionProbeCounts

    var probeCount: Int {
        counts.emitted
    }

    var acceptCount: Int {
        counts.accepted
    }

    var cacheHitCount: Int {
        counts.rejectedByCache
    }

    var decoderRejectCount: Int {
        counts.decoderRejections
    }

    let anyAccepted: Bool
    let anyRequiresRebuild: Bool
    let latestTreeIsStripped: Bool

    let convergenceRecords: [Int: ConvergedOrigin]
    let hadReplacementShortlexRejection: Bool

    /// Leaf node IDs whose values changed in accepted probes during this pass.
    let acceptedLeafNodeIDs: Set<Int>
}
