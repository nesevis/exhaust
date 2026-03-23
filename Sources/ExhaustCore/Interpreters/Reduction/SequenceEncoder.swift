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
    case linearScan
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

