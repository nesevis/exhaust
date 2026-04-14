// MARK: - Composable Encoder Protocol

/// Produces candidate mutations for a position range in the choice sequence.
///
/// Composable encoders are role-agnostic probe strategies. Each operates on a scoped position range and produces candidate sequences — it does not know or care whether it is assigned to the upstream role (proposing fibres), the downstream role (exploring within a fibre), or the standalone role (evaluated directly). The role is determined by where the scheduler places the encoder in the pipeline based on the ``ChoiceDependencyGraph``, not by the encoder itself.
///
/// ## Composability
///
/// A ``GraphComposedEncoder`` composes two composable encoders through a generator lift. The upstream encoder's output is lifted (materialized without property check) to produce a fresh `(sequence, tree)` for the downstream encoder. The property is checked only on the downstream's final output.
public protocol ComposableEncoder {
    /// Typed identifier for dominance pruning and logging.
    var name: EncoderName { get }

    /// Estimates the number of probes this encoder will generate for the given position range, or returns `nil` if the encoder has no applicable targets and should be skipped entirely.
    func estimatedCost(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>
    ) -> Int?

    /// Initializes internal state for a new encoding pass.
    ///
    /// Called once by the scheduler before the probe loop begins, or once per upstream probe in a ``GraphComposedEncoder`` (where the downstream encoder is re-initialized on the lifted sequence after each upstream candidate).
    mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>
    )

    /// Produces the next probe given feedback on the previous one.
    ///
    /// - Parameter lastAccepted: Whether the previous probe was accepted. Ignored on the first call after ``start(sequence:tree:positionRange:)``.
    /// - Returns: The next candidate to try, or `nil` when converged.
    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence?

    /// Convergence records accumulated during the probe loop.
    ///
    /// Each entry maps a flat sequence index to the ``ConvergedOrigin`` at which the search converged.
    var convergenceRecords: [Int: ConvergedOrigin] { get }

    /// Whether convergence records from the previous run are compatible with this run.
    ///
    /// Returns `true` by default — the encoder's semantics have not changed between runs. ``GraphComposedEncoder`` checks this after ``start()`` and cold-starts the convergence transfer when it returns `false`.
    var isConvergenceTransferSafe: Bool { get }
}

public extension ComposableEncoder {
    /// Default implementation returning no convergence records.
    var convergenceRecords: [Int: ConvergedOrigin] {
        [:]
    }

    /// Default: convergence transfer is always safe (same encoder semantics across runs).
    var isConvergenceTransferSafe: Bool {
        true
    }

    /// Default cost estimate: nil (no work to do). Conformers should override.
    func estimatedCost(
        sequence _: ChoiceSequence,
        tree _: ChoiceTree,
        positionRange _: ClosedRange<Int>
    ) -> Int? {
        nil
    }
}
