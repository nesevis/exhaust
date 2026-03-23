/// Typed identifier for a sequence encoder, used in dominance pruning and logging.
public enum EncoderName: String, Hashable, Sendable {
    // Structural deletion
    case deleteByPromotingSimplestBranch
    case deleteByPivotingToAlternativeBranch
    case deleteContainerSpans
    case deleteSequenceElements
    case deleteSequenceBoundaries
    case deleteFreeStandingValues
    case deleteContainerSpansWithRandomRepair
    case deleteAlignedSiblingWindows
    // Value minimization
    case zeroValue
    case binarySearchToSemanticSimplest
    case binarySearchToRangeMinimum
    case reduceFloat
    case bindRootSearch
    case productSpaceBatch
    case productSpaceAdaptive
    // Redistribution
    case redistributeSiblingValuesInLockstep
    case redistributeArbitraryValuePairsAcrossContainers
    case redistributeInnerValuesBetweenBindRegions
    /// Exploration
    case relaxRound
    case kleisliComposition
}

/// Shared metadata for all reduction encoders.
public protocol SequenceEncoderBase {
    /// Typed identifier used for dominance pruning and logging.
    var name: EncoderName { get }

    /// Which phase this encoder belongs to.
    var phase: ReductionPhase { get }

    /// Estimates the number of probes this encoder will generate for the given sequence, or returns `nil` if the encoder has no applicable targets and should be skipped entirely.
    ///
    /// The scheduler calls this once per cycle to sort encoders cheapest-first and filter out ineligible ones. The estimate is derived from the encoder's algorithmic complexity and the target count visible in the choice sequence.
    ///
    /// - Parameters:
    ///   - sequence: The current choice sequence.
    ///   - bindIndex: The bind span index, or `nil` if the generator has no binds.
    /// - Returns: Estimated probe count, or `nil` if this encoder has no work to do.
    func estimatedCost(sequence: ChoiceSequence, bindIndex: BindSpanIndex?) -> Int?
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
    /// Called once by the scheduler before the probe loop begins. The encoder captures the starting sequence and targets, and builds whatever internal state it needs. Converged origins from the ``ConvergenceCache`` narrow binary search ranges for encoders that support them.
    mutating func start(sequence: ChoiceSequence, targets: TargetSet, convergedOrigins: [Int: ConvergedOrigin]?)

    /// Produces the next probe given feedback on the previous one.
    ///
    /// - Parameter lastAccepted: Whether the previous probe was accepted by the decoder. Ignored on the first call after ``start(sequence:targets:convergedOrigins:)``.
    /// - Returns: The next candidate to try, or `nil` when converged.
    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence?

    /// Convergence records accumulated during the probe loop.
    ///
    /// Each entry maps a flat sequence index to the ``ConvergedOrigin`` at which the search converged. Harvested by ``ReductionState/runAdaptive(_:decoder:targets:structureChanged:budget:fingerprintGuard:convergedOrigins:)`` into the ``ConvergenceCache`` and ``ConvergenceInstrumentation``.
    var convergenceRecords: [Int: ConvergedOrigin] { get }
}

public extension AdaptiveEncoder {
    /// Convenience overload for callers that do not pass converged origins.
    mutating func start(sequence: ChoiceSequence, targets: TargetSet) {
        start(sequence: sequence, targets: targets, convergedOrigins: nil)
    }

    /// Default implementation returning no convergence records.
    var convergenceRecords: [Int: ConvergedOrigin] {
        [:]
    }
}
