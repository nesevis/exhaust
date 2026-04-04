//
//  GraphEncoder.swift
//  Exhaust
//

// MARK: - Graph Encoder Protocol

/// A reduction encoder that receives its scope, candidates, and ordering from a ``ChoiceGraph``.
///
/// `GraphEncoder` is the ChoiceGraph-based counterpart of ``ComposableEncoder``. The two protocols have fundamentally different interfaces: `ComposableEncoder` receives a position range and computes its own scope from the sequence; `GraphEncoder` receives the graph directly and constructs probes from graph operations.
///
/// Both protocols share the materialiser (`SequenceDecoder.decode`), property invocation, and ``ReductionResult`` infrastructure. The ``ChoiceGraphScheduler`` speaks `GraphEncoder`; the ``BonsaiScheduler`` speaks `ComposableEncoder`.
///
/// ## Lifecycle
///
/// 1. The scheduler calls ``start(graph:sequence:tree:)`` with the current graph and sequence.
/// 2. The scheduler calls ``nextProbe(lastAccepted:)`` in a loop until it returns nil (converged).
/// 3. The scheduler reads ``convergenceRecords`` after the loop to harvest cached bounds.
public protocol GraphEncoder {
    /// Descriptive name for logging and instrumentation.
    var name: EncoderName { get }

    /// Initialises internal state for a new encoding pass.
    ///
    /// Called once per cycle (or once per scheduler phase) with the current graph, sequence, and tree. The encoder extracts the candidates it needs from the graph and prepares its probe state machine.
    mutating func start(
        graph: ChoiceGraph,
        sequence: ChoiceSequence,
        tree: ChoiceTree
    )

    /// Produces the next candidate sequence given feedback on the previous probe.
    ///
    /// - Parameter lastAccepted: Whether the previous probe was accepted by the property. Ignored on the first call after ``start(graph:sequence:tree:)``.
    /// - Returns: The next candidate to try, or `nil` when converged.
    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence?

    /// Convergence records accumulated during the probe loop.
    ///
    /// Each entry maps a flat sequence index to the ``ConvergedOrigin`` at which the search converged. The scheduler harvests these after the probe loop to warm-start future passes.
    var convergenceRecords: [Int: ConvergedOrigin] { get }
}

public extension GraphEncoder {
    /// Default implementation returning no convergence records.
    var convergenceRecords: [Int: ConvergedOrigin] {
        [:]
    }
}
