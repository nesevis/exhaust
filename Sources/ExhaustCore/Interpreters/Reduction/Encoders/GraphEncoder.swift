//
//  GraphEncoder.swift
//  Exhaust
//

// MARK: - Encoder Probe

/// The mutation a probe would enact if accepted, returned by ``GraphEncoder/nextProbe(into:lastAccepted:)``.
///
/// The candidate sequence itself is written into the caller-owned `inout` buffer to avoid per-probe COW allocation. The mutation carries everything the graph needs to update itself in place; for value-only encoders it is a ``ProjectedMutation/leafValues(_:)`` listing the changed leaves with their bind-inner reshape markers.
///
/// - SeeAlso: ``ProjectedMutation``, ``LeafChange``, ``ChoiceGraph/apply(_:freshTree:)``
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

    /// True when the encoder's probe candidates are post-lift sequences whose bound subtree differs from ``EncoderInput/tree``.
    ///
    /// The scheduler routes such probes through ``SequenceDecoder/exact(materializePicks:)`` instead of the bind-aware guided decoder, because guided decoding would substitute stale bound-subtree content from the parent tree's fallback path. Default `false` for all intra-skeleton encoders. Composed encoders that drive a generator lift internally (such as ``GraphComposedEncoder``) override this to `true`.
    var requiresExactDecoder: Bool { get }

    /// Initialises internal state for a new encoding pass.
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

    /// Re-derives the encoder's scope state from the live graph after a structural mutation.
    ///
    /// The scheduler calls this between ``nextProbe(into:lastAccepted:)`` invocations whenever the most recent probe acceptance added or removed graph nodes (any in-place reshape that adds/removes nodes, or any mutation flagged ``ChangeApplication/requiresFullRebuild``). At that point the encoder's per-pass cached state — leaf positions, in-flight binary-search steppers, pair indices — is no longer valid against the live graph: tombstoned nodes are still referenced, surviving nodes have shifted positions, and any new nodes the splice created are invisible.
    ///
    /// Implementations must:
    ///
    /// 1. Re-walk the live graph and rebuild every nodeID-keyed cache (leaf positions, pair plans, lookup tables) from the current state.
    /// 2. Drop in-flight per-leaf iteration state (steppers, scan windows, cross-zero phases) — those refer to the old leaf set and are not meaningful after re-scoping.
    /// 3. Preserve convergence records by nodeID. Records whose nodeID is now tombstoned (`positionRange == nil`) should be dropped; surviving nodeIDs keep their records.
    /// 4. Update the encoder's internal sequence reference (``IntegerState/sequence`` and similar) to match the live `sequence` parameter.
    ///
    /// The default implementation is a no-op, suitable for single-shot encoders that emit one probe per scope (for example, ``GraphStructuralEncoder``, ``GraphSwapEncoder``, ``GraphReorderEncoder``) and for encoders that already self-reset on every accepted probe. Stateful encoders that cache leaf positions across multiple probes within a pass (``GraphValueEncoder``, ``GraphRedistributionEncoder``) must override this method.
    ///
    /// - Parameters:
    ///   - graph: The live graph after the structural mutation.
    ///   - sequence: The live sequence after the structural mutation. Encoders that cache a baseline sequence in their state must replace it with this value, since their cached copy is from before the mutation.
    mutating func refreshState(graph: ChoiceGraph, sequence: ChoiceSequence)

    /// Whether every cached sequence position still addresses a value entry in the given sequence.
    ///
    /// The probe loop calls this after an acceptance whose ``ChangeApplication`` indicates a partial graph modification (value writes landed but bind reshape did not complete). When true, the encoder's cached leaf positions are still usable against the post-acceptance sequence and the probe loop can continue without a cycle break. When false, at least one cached position now addresses a structural marker or is out of bounds, and the loop must break to trigger a full rebuild.
    ///
    /// The default returns true, which is correct for encoders that do not cache per-leaf sequence indices (structural, swap, reorder, and similar single-shot encoders).
    func hasValidPositions(in sequence: ChoiceSequence) -> Bool

    /// Convergence records accumulated during the probe loop.
    ///
    /// Each entry maps a graph **nodeID** to the ``ConvergedOrigin`` at which the search converged for that leaf. The scheduler harvests these after the probe loop and writes them to the graph via ``ChoiceGraph/recordConvergence(byNodeID:)``. NodeID keying (rather than sequence index) is required so the records survive in-pass position shifts triggered by ``refreshState(graph:sequence:)``.
    var convergenceRecords: [Int: ConvergedOrigin] { get }

    /// Writes partial convergence records for any in-progress search that was interrupted by a probe loop break.
    ///
    /// The scheduler calls this before harvesting ``convergenceRecords`` so that the stepper's best-accepted bound survives the graph rebuild and narrows the search range on the next dispatch via warm start.
    mutating func flushPartialConvergence()
}

extension GraphEncoder {
    /// Default: encoders use the scheduler's hasBind-aware decoder selection.
    var requiresExactDecoder: Bool {
        false
    }

    /// Default: no partial convergence to flush.
    mutating func flushPartialConvergence() {}

    /// Default: all cached positions are valid.
    func hasValidPositions(in _: ChoiceSequence) -> Bool {
        true
    }

    /// Default implementation returning no convergence records.
    var convergenceRecords: [Int: ConvergedOrigin] {
        [:]
    }

    /// Default no-op refresh for single-shot and self-resetting encoders.
    ///
    /// Correct for encoders whose ``nextProbe(into:lastAccepted:)`` returns nil after one probe (single-shot pattern: ``GraphRemovalEncoder``, ``GraphPermutationEncoder``, ``GraphMigrationEncoder``) and for encoders that transition to ``Mode/idle`` on every accepted probe (``GraphReplacementEncoder``). Stateful encoders that cache leaf positions across multiple probes within one pass must override.
    mutating func refreshState(graph _: ChoiceGraph, sequence _: ChoiceSequence) {}
}
