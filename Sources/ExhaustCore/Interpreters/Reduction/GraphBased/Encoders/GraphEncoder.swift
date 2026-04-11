//
//  GraphEncoder.swift
//  Exhaust
//

// MARK: - Encoder Probe

/// A candidate sequence paired with the mutation it would enact if accepted.
///
/// Encoders return ``EncoderProbe`` from ``GraphEncoder/nextProbe(lastAccepted:)`` so that the scheduler can route the projected mutation to ``ChoiceGraph/apply(_:freshTree:)`` after acceptance without having to diff the result against the prior tree. The ``mutation`` field carries everything the graph needs to update itself in place; for value-only encoders it is a ``ProjectedMutation/leafValues(_:)`` listing the changed leaves with their bind-inner reshape markers.
///
/// - SeeAlso: ``ProjectedMutation``, ``LeafChange``, ``ChoiceGraph/apply(_:freshTree:)``
struct EncoderProbe {
    /// The candidate ``ChoiceSequence`` to pass to the decoder.
    let candidate: ChoiceSequence

    /// The mutation that would enact if the property still fails on ``candidate``.
    let mutation: ProjectedMutation
}

// MARK: - Graph Encoder Protocol

/// The encoding half of the SJ algebra's (enc_a, dec_a) morphism pair for graph-based reduction.
///
/// Receives a ``TransformationScope`` (self-contained: base sequence, operation metadata, warm-start records) and produces candidate sequences via its probe loop. Each candidate is passed to the decoder (``SequenceDecoder``, the dec_a half) for materialisation and property checking.
///
/// The scope defines the search space (graph-computable). The encoder determines how to explore it (predicate-dependent). This separation is the opacity boundary: the scope is constructed by the scheduler from graph metadata; the encoder searches within it using predicate feedback.
///
/// Active-path encoders (removal, minimization, exchange, permutation) produce candidates via sequence surgery on ``TransformationScope/baseSequence`` at pre-resolved position ranges. Path-changing encoders (replacement with inactive donor) edit ``TransformationScope/tree`` and flatten.
///
/// ## Lifecycle
///
/// 1. The scheduler calls ``start(scope:)`` with a self-contained scope.
/// 2. The scheduler calls ``nextProbe(lastAccepted:)`` in a loop until it returns nil (converged).
/// 3. The scheduler reads ``convergenceRecords`` after the loop to harvest cached bounds.
protocol GraphEncoder {
    /// Descriptive name for logging and instrumentation.
    var name: EncoderName { get }

    /// True when the encoder's probe candidates are post-lift sequences whose fibre differs from ``TransformationScope/tree``.
    ///
    /// The scheduler routes such probes through ``SequenceDecoder/exact(materializePicks:)`` instead of the bind-aware guided decoder, because guided decoding would substitute stale bound-subtree content from the parent tree's fallback path. Default `false` for all intra-skeleton encoders. Composed encoders that drive a generator lift internally (such as ``GraphComposedEncoder``) override this to `true`.
    var requiresExactDecoder: Bool { get }

    /// Initialises internal state for a new encoding pass.
    ///
    /// Called once per scope dispatch. The encoder extracts candidates from the scope's operation metadata and prepares its probe state machine. The encoder reads warm-start data from ``TransformationScope/warmStartRecords`` — it never accesses the graph directly.
    mutating func start(scope: TransformationScope)

    /// Produces the next probe given feedback on the previous probe.
    ///
    /// The returned ``EncoderProbe`` pairs the candidate sequence with a ``ProjectedMutation`` describing what the graph should update if the candidate is accepted. The scheduler forwards the mutation to ``ChoiceGraph/apply(_:freshTree:)``.
    ///
    /// - Parameter lastAccepted: Whether the previous probe was accepted by the property. Ignored on the first call after ``start(scope:)``.
    /// - Returns: The next probe to try, or `nil` when converged.
    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe?

    /// Re-derives the encoder's scope state from the live graph after a structural mutation.
    ///
    /// The scheduler calls this between ``nextProbe(lastAccepted:)`` invocations whenever the most recent probe acceptance added or removed graph nodes (any in-place reshape that adds/removes nodes, or any mutation flagged ``ChangeApplication/requiresFullRebuild``). At that point the encoder's per-pass cached state — leaf positions, in-flight binary-search steppers, pair indices — is no longer valid against the live graph: tombstoned nodes are still referenced, surviving nodes have shifted positions, and any new nodes the splice created are invisible.
    ///
    /// Implementations must:
    ///
    /// 1. Re-walk the live graph and rebuild every nodeID-keyed cache (leaf positions, pair plans, lookup tables) from the current state.
    /// 2. Drop in-flight per-leaf iteration state (steppers, scan windows, cross-zero phases) — those refer to the old leaf set and are not meaningful after re-scoping.
    /// 3. Preserve convergence records by nodeID. Records whose nodeID is now tombstoned (`positionRange == nil`) should be dropped; surviving nodeIDs keep their records.
    /// 4. Update the encoder's internal sequence reference (``IntegerState/sequence`` and similar) to match the live `sequence` parameter.
    ///
    /// The default implementation is a no-op, suitable for single-shot encoders that emit one probe per scope (for example, ``GraphRemovalEncoder``, ``GraphPermutationEncoder``, ``GraphMigrationEncoder``) and for encoders that already self-reset on every accepted probe (for example, ``GraphReplacementEncoder``). Stateful encoders that cache leaf positions across multiple probes within a pass (``GraphValueEncoder``, ``GraphExchangeEncoder``) must override this method.
    ///
    /// - Parameters:
    ///   - graph: The live graph after the structural mutation.
    ///   - sequence: The live sequence after the structural mutation. Encoders that cache a baseline sequence in their state must replace it with this value, since their cached copy is from before the mutation.
    mutating func refreshScope(graph: ChoiceGraph, sequence: ChoiceSequence)

    /// Convergence records accumulated during the probe loop.
    ///
    /// Each entry maps a graph **nodeID** to the ``ConvergedOrigin`` at which the search converged for that leaf. The scheduler harvests these after the probe loop and writes them to the graph via ``ChoiceGraph/recordConvergence(byNodeID:)``. NodeID keying (rather than sequence index) is required so the records survive in-pass position shifts triggered by ``refreshScope(graph:sequence:)``.
    var convergenceRecords: [Int: ConvergedOrigin] { get }
}

extension GraphEncoder {
    /// Default: encoders use the scheduler's hasBind-aware decoder selection.
    var requiresExactDecoder: Bool {
        false
    }

    /// Default implementation returning no convergence records.
    var convergenceRecords: [Int: ConvergedOrigin] {
        [:]
    }

    /// Default no-op refresh for single-shot and self-resetting encoders.
    ///
    /// Correct for encoders whose ``nextProbe(lastAccepted:)`` returns nil after one probe (single-shot pattern: ``GraphRemovalEncoder``, ``GraphPermutationEncoder``, ``GraphMigrationEncoder``) and for encoders that transition to ``Mode/idle`` on every accepted probe (``GraphReplacementEncoder``). Stateful encoders that cache leaf positions across multiple probes within one pass must override.
    mutating func refreshScope(graph _: ChoiceGraph, sequence _: ChoiceSequence) {}
}
