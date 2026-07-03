//
//  GraphEncoder.swift
//  Exhaust
//

// MARK: - Encoder Probe

/// The mutation a probe would enact if accepted, returned by ``GraphEncoder/nextProbe(into:lastAccepted:)``.
///
/// The candidate sequence itself is written into the caller-owned `inout` buffer to avoid per-probe COW allocation. The mutation carries everything the graph needs to update itself in place; for value-only encoders it is a ``ProjectedMutation/leafValues(_:)`` listing the changed leaves with their bind-inner reshape markers.
///
/// - SeeAlso: ``ProjectedMutation``, ``LeafChange``, ``ChoiceGraph/apply(_:)``
typealias EncoderProbe = ProjectedMutation

// MARK: - Graph Encoder Protocol

/// Produces candidate sequences for a given operation scope.
///
/// Receives an ``EncoderInput`` (self-contained: base sequence, operation metadata, warm-start records) and produces candidate sequences via its probe loop. Each candidate is passed to the decoder (``SequenceDecoder``) for materialisation and property checking.
///
/// The scope defines the search space (graph-computable). The encoder determines how to explore it (predicate-dependent). The scheduler constructs scopes from graph metadata; the encoder searches within them using predicate feedback.
///
/// Active-path encoders (removal, minimization, exchange, permutation) produce candidates via sequence surgery on ``EncoderInput/baseSequence`` at pre-resolved position ranges. Path-changing encoders (replacement with inactive donor) edit ``EncoderInput/tree`` and flatten.
///
/// ## Lifecycle
///
/// 1. The scheduler calls ``start(scope:)`` with a self-contained scope.
/// 2. The scheduler calls ``nextProbe(into:lastAccepted:)`` in a loop until it returns nil (converged). The caller owns the candidate buffer and passes it as `inout`; the encoder writes the candidate directly into it.
/// 3. The scheduler reads ``convergenceRecords`` after the loop to harvest cached bounds.
protocol GraphEncoder {
    /// Descriptive name for logging and instrumentation.
    var name: EncoderName { get }

    /// Initializes internal state for a new encoding pass.
    ///
    /// Called once per scope dispatch. The encoder extracts candidates from the scope's operation metadata and prepares its probe state machine. The encoder reads warm-start data from ``EncoderInput/warmStartRecords`` — it never accesses the graph directly.
    mutating func start(scope: EncoderInput)

    /// Produces the next probe by writing the candidate into `candidate` and returning the projected mutation.
    ///
    /// The caller owns the candidate buffer and passes it as `inout`. The encoder overwrites it with the next candidate sequence. This avoids per-probe COW allocation — the same buffer is reused across all probes in the loop.
    ///
    /// - Parameters:
    ///   - candidate: Caller-owned buffer that the encoder writes the candidate sequence into.
    ///   - lastAccepted: Whether the previous probe was accepted by the property. Ignored on the first call after ``start(scope:)``.
    /// - Returns: The projected mutation for this probe, or `nil` when converged.
    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe?

    /// Whether any replacement probe was rejected because the candidate was not shortlex-smaller than the original.
    ///
    /// The scheduler uses this to decide whether a relax round is worth attempting after structural reduction completes. Default `false` for non-structural encoders.
    var hadReplacementShortlexRejection: Bool { get }

    /// Convergence records accumulated during the probe loop.
    ///
    /// Each entry maps a graph **nodeID** to the ``ConvergedOrigin`` at which the search converged for that leaf. The scheduler harvests these after the probe loop and writes them to the graph via ``ChoiceGraph/recordConvergence(byNodeID:)``. NodeID keying (rather than sequence index) is required so the records survive in-pass position shifts triggered by ``refreshState(graph:sequence:)``.
    var convergenceRecords: [Int: ConvergedOrigin] { get }

    /// Writes partial convergence records for any in-progress search that was interrupted by a probe loop break.
    ///
    /// The scheduler calls this before harvesting ``convergenceRecords`` so that the stepper's best-accepted bound survives the graph rebuild and narrows the search range on the next dispatch via warm start.
    mutating func flushPartialConvergence()
}

/// An encoder whose probe candidates are post-lift sequences with a bound subtree that differs from ``EncoderInput/tree``.
///
/// The scheduler routes probes from stateful encoders through ``SequenceDecoder/exact(materializePicks:)`` instead of the bind-aware guided decoder, because guided decoding would substitute stale bound-subtree content from the parent tree's fallback path. After each accepted probe that triggers a structural mutation, the scheduler calls ``refreshState(graph:sequence:)`` so the encoder can re-derive its cached state from the live graph.
protocol StatefulGraphEncoder: GraphEncoder {
    /// Re-derives the encoder's scope state from the live graph after a structural mutation.
    ///
    /// The scheduler calls this between ``nextProbe(into:lastAccepted:)`` invocations whenever the most recent probe acceptance triggered a structural mutation. At that point the encoder's per-pass cached state — leaf positions, in-flight binary-search steppers, pair indices — may reference nodes that no longer exist or have different positions in the rebuilt graph.
    ///
    /// Implementations must:
    ///
    /// 1. Re-walk the live graph and rebuild every nodeID-keyed cache (leaf positions, pair plans, lookup tables) from the current state.
    /// 2. Drop in-flight per-leaf iteration state (steppers, scan windows, cross-zero phases) — those refer to the old leaf set and are not meaningful after re-scoping.
    /// 3. Preserve convergence records by nodeID. Records whose nodeID no longer has a position range should be dropped; surviving nodeIDs keep their records.
    /// 4. Update the encoder's internal sequence reference (``IntegerState/sequence`` and similar) to match the live `sequence` parameter.
    ///
    /// - Parameters:
    ///   - graph: The live graph after the structural mutation.
    ///   - sequence: The live sequence after the structural mutation. Encoders that cache a baseline sequence in their state must replace it with this value, since their cached copy is from before the mutation.
    mutating func refreshState(graph: ChoiceGraph, sequence: ChoiceSequence)
}

extension GraphEncoder {
    /// Default: no replacement shortlex rejections.
    var hadReplacementShortlexRejection: Bool {
        false
    }

    /// Default: no partial convergence to flush.
    mutating func flushPartialConvergence() {}

    /// Default implementation returning no convergence records.
    var convergenceRecords: [Int: ConvergedOrigin] {
        [:]
    }
}
