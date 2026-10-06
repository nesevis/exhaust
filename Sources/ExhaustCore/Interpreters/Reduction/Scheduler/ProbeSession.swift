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
    var probeWrapper: ProbeWrapper? { get }
    var rejectCache: Set<UInt64> { get set }
    var collectStats: Bool { get }
    var isInstrumented: Bool { get }
}

extension ProbeSessionState {
    /// The property with the host's wrapper around it, carrying the candidate the probe is testing.
    ///
    /// Built per decode rather than once, because the sequence it reports is the one being decoded. Returns `property` unchanged when there is no wrapper, so a host that does not observe probes allocates no closure.
    func wrappedProperty(for candidate: ChoiceSequence) -> (Any) -> Bool {
        guard let probeWrapper else {
            return property
        }
        let hostProperty = property
        return { output in
            probeWrapper(candidate) { hostProperty(output) }
        }
    }
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

    /// Characterization tests require one terminal event per emitted probe, including interrupted decodes. Scheduler sessions leave this nil.
    private let observer: ((ProbeObservation) -> Void)?
    private var nextProbeID = 0
    private var pendingObservationID: Int?

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
        hasBind: Bool,
        observer: ((ProbeObservation) -> Void)? = nil
    ) {
        self.encoder = encoder
        self.transformation = transformation
        self.boundValueFingerprint = boundValueFingerprint
        baseHash = ZobristHash.hash(of: baseSequence)
        self.hasBind = hasBind
        candidateBuffer = baseSequence
        self.observer = observer
    }

    // MARK: - Step

    /// Advances the session by one encode or decode sub-phase.
    mutating func step(state: inout some ProbeSessionState) throws -> StepResult {
        switch phase {
            case .encode:
                return stepEncode(state: &state)
            case .decode:
                do {
                    return try stepDecode(state: &state)
                } catch {
                    terminateObservation(.interrupted)
                    throw error
                }
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

        if let observer {
            nextProbeID += 1
            pendingObservationID = nextProbeID
            observer(.emitted(probeID: nextProbeID, sequence: candidateBuffer, mutation: mutation))
        }

        let probeHash = ZobristHash.incrementalHash(
            baseHash: baseHash,
            baseSequence: state.sequence,
            probe: candidateBuffer
        )
        if state.rejectCache.contains(probeHash) {
            counts.recordCacheRejection()
            terminateObservation(.cacheRejected)
            return .encoded(encoder: encoder.name, cacheHit: true)
        }

        let selection = ChoiceGraphScheduler.selectDecoder(
            for: mutation,
            requiresExactDecoder: encoder.requiresExactDecoder,
            hasBind: hasBind,
            admission: encoder.admission
        )

        if let pendingObservationID {
            observer?(.decoderSelected(
                probeID: pendingObservationID,
                preferExact: selection.preferExact,
                materializePicks: selection.materializePicks
            ))
        }

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

        let decoder = selection.decoder(fallbackTree: state.tree)

        var filterObservations: [UInt64: FilterObservation] = [:]

        let outcome = try decoder.decodeAny(
            candidate: candidateBuffer,
            gen: state.gen,
            tree: state.tree,
            originalSequence: state.sequence,
            property: state.wrappedProperty(for: candidateBuffer),
            filterObservations: &filterObservations,
            precomputedHash: pendingProbeHash
        )
        counts.recordOutcome(outcome)
        if let pendingObservationID, let result = outcome.reduction {
            observer?(.decoded(probeID: pendingObservationID, sequence: result.sequence))
        }

        // Gate on the decoded sequence, not the encoder's candidate: exact materialization re-derives bind wrappers, so a shorter candidate can decode to an enlarging commit and a substitution pair can cycle until the deadline. Equal-comparing commits are lateral moves and stay admissible. numericReorder is exempt: it deliberately regresses shortlex to ascending numeric order.
        if let result = outcome.reduction,
           encoderName == .numericReorder || state.sequence.shortLexPrecedes(result.sequence) == false
        {
            counts.recordAcceptance()
            state.sequence = result.sequence
            state.tree = result.tree
            state.output = result.output
            baseHash = ZobristHash.hash(of: state.sequence)
            lastProbeAccepted = true
            anyAccepted = true
            terminateObservation(.accepted, materializationAttempts: outcome.materializationAttempts)

            if case let .leafValues(changes) = mutation {
                for change in changes {
                    acceptedLeafNodeIDs.insert(change.leafNodeID)
                }
            }

            latestTreeIsStripped = selection.materializePicks == false

            switch encoder.acceptanceHandling {
                case .refreshAndIdle:
                    anyRequiresRebuild = true
                    encoder.refreshState(graph: state.graph, sequence: state.sequence)
                case .applyMutation:
                    let application = state.graph.apply(mutation)
                    if application.requiresFullRebuild {
                        anyRequiresRebuild = true
                        phase = .finished
                        return .decoded(encoder: encoderName, accepted: true)
                    }
            }

            phase = .encode
            return .decoded(encoder: encoderName, accepted: true)
        }

        let disposition: ProbeDisposition = switch outcome {
            case .materializationRejected:
                .materializationRejected
            case .propertyPassed:
                .propertyPassed
            case let .propertyFailed(reduction, _):
                .propertyFailedNotAdmitted(reduction == nil ? .decoderReturnedNoReduction : .enlargingCommit)
        }
        terminateObservation(disposition, materializationAttempts: outcome.materializationAttempts)

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

    /// Completes an observed probe once, including when a caller stops with decoding still pending.
    private mutating func terminateObservation(
        _ disposition: ProbeDisposition,
        materializationAttempts: Int = 0
    ) {
        guard let pendingObservationID else {
            return
        }
        observer?(.terminated(
            probeID: pendingObservationID,
            disposition: disposition,
            materializationAttempts: materializationAttempts
        ))
        self.pendingObservationID = nil
    }

    // MARK: - Report

    /// Produces the pass report by flushing partial convergence and snapshotting all counters.
    mutating func report() -> PassReport {
        terminateObservation(.interrupted)
        encoder.flushPartialConvergence()

        return PassReport(
            encoderName: encoder.name,
            transformation: transformation,
            boundValueFingerprint: boundValueFingerprint,
            composedUpstreamLifts: encoder.composedUpstreamProbesUsed,
            liftMaterializations: encoder.liftMaterializations,
            counts: counts,
            anyAccepted: anyAccepted,
            anyRequiresRebuild: anyRequiresRebuild,
            latestTreeIsStripped: latestTreeIsStripped,
            convergenceRecords: encoder.convergenceRecords,
            hadUnresolvedReplacement: encoder.hadUnresolvedReplacement,
            acceptedLeafNodeIDs: acceptedLeafNodeIDs
        )
    }

    // MARK: - Run To Completion

    /// Stops before the next encode or decode step when the deadline expires, reporting all work already performed.
    ///
    /// Checking every step also bounds runs consisting entirely of cache rejections. A pending undecoded probe is interrupted by ``report()``; an in-flight decode completes before the next check.
    mutating func runToCompletion(
        state: inout some ProbeSessionState,
        deadlineCheck: (() -> Bool)? = nil
    ) throws -> PassReport {
        while phase != .finished {
            guard deadlineCheck?() != true else {
                phase = .finished
                break
            }
            _ = try step(state: &state)
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

    /// Materializations the encoder ran outside the probe decoder, for lifting encoders; nil for every other encoder.
    let liftMaterializations: (site: MaterializationSite, count: Int)?

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
    let hadUnresolvedReplacement: Bool

    /// Leaf node IDs whose values changed in accepted probes during this pass.
    let acceptedLeafNodeIDs: Set<Int>
}
