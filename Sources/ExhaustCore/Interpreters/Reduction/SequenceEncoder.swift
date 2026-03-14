/// Shared metadata for all reduction encoders.
public protocol SequenceEncoderBase {
    /// Human-readable name for logging.
    var name: String { get }

    /// Declared grade: approximation bound and resource bound.
    var grade: ReductionGrade { get }

    /// Which phase this encoder belongs to.
    var phase: ReductionPhase { get }
}

/// Batch encoding: all candidates produced upfront, scheduler picks first success.
///
/// Pure and stateless. The scheduler evaluates candidates in order, stopping at the first success (angelic resolution).
public protocol BatchEncoder: SequenceEncoderBase {
    /// Produces candidate mutations, best first.
    ///
    /// Returns a lazy sequence of candidates. The scheduler filters through the reject cache and decodes each until one succeeds.
    func encode(
        sequence: ChoiceSequence,
        targets: TargetSet
    ) -> any Sequence<ChoiceSequence>
}

/// Adaptive encoding: one probe at a time, feedback-driven.
///
/// Conformers are stateful — they maintain internal search state (for example, `[lo, hi]` bounds per target for binary search). The scheduler drives the loop; the encoder navigates a decision tree based on acceptance/rejection feedback.
///
/// The encoder never sees the decoded output — only whether each probe was accepted.
public protocol AdaptiveEncoder: SequenceEncoderBase {
    /// Initializes internal state for a new encoding pass.
    ///
    /// Called once by the scheduler before the probe loop begins. The encoder captures the starting sequence and targets, and builds whatever internal state it needs.
    mutating func start(sequence: ChoiceSequence, targets: TargetSet)

    /// Produces the next probe given feedback on the previous one.
    ///
    /// - Parameter lastAccepted: Whether the previous probe was accepted by the decoder. Ignored on the first call after ``start(sequence:targets:)``.
    /// - Returns: The next candidate to try, or `nil` when converged.
    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence?
}

/// A branch encoder that operates on the tree structure rather than on value spans.
///
/// Branch tactics (promote, pivot) need the tree to identify branch points and available alternatives. They return candidate sequences only — the scheduler passes each through `.guided` to rebuild the tree.
public protocol BranchEncoder {
    /// Human-readable name for logging.
    var name: String { get }

    /// Declared grade: approximation bound and resource bound.
    var grade: ReductionGrade { get }

    /// Produces candidate branch mutations.
    func encode(
        sequence: ChoiceSequence,
        tree: ChoiceTree
    ) -> any Sequence<ChoiceSequence>
}
