//
//  GraphEncoder.swift
//  Exhaust
//

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

    /// Initialises internal state for a new encoding pass.
    ///
    /// Called once per scope dispatch. The encoder extracts candidates from the scope's operation metadata and prepares its probe state machine. The encoder reads warm-start data from ``TransformationScope/warmStartRecords`` — it never accesses the graph directly.
    mutating func start(scope: TransformationScope)

    /// Produces the next candidate sequence given feedback on the previous probe.
    ///
    /// - Parameter lastAccepted: Whether the previous probe was accepted by the property. Ignored on the first call after ``start(scope:)``.
    /// - Returns: The next candidate to try, or `nil` when converged.
    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence?

    /// Convergence records accumulated during the probe loop.
    ///
    /// Each entry maps a flat sequence index to the ``ConvergedOrigin`` at which the search converged. The scheduler harvests these after the probe loop to warm-start future passes.
    var convergenceRecords: [Int: ConvergedOrigin] { get }
}

extension GraphEncoder {
    /// Default implementation returning no convergence records.
    var convergenceRecords: [Int: ConvergedOrigin] {
        [:]
    }
}
