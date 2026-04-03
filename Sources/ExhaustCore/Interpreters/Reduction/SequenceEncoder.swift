/// Typed identifier for a sequence encoder, used in dominance pruning and logging.
public enum EncoderName: String, Hashable, Sendable {
    // Structural deletion
    case promoteDirectDescendantBranch
    case deleteByPromotingSimplestBranch
    case deleteByPivotingToAlternativeBranch
    case deleteContainerSpans
    case deleteSequenceElements
    case deleteSequenceBoundaries
    case deleteFreeStandingValues
    case deleteContainerSpansWithRandomRepair
    case deleteAlignedSiblingWindows
    case deleteAlignedSiblingSubsets
    case bindSubstitution
    case swapSiblings
    // Value minimization
    case zeroValue
    case binarySearchToSemanticSimplest
    case reduceFloat
    case productSpaceBatch
    case productSpaceAdaptive
    case shortlexReorder
    // Redistribution
    case redistributeSiblingValuesInLockstep
    case redistributeArbitraryValuePairsAcrossContainers
    case linearScan
    /// Exploration
    case relaxRound
    case kleisliComposition
    // Reduction passes
    case branchProjection
    case freeCoordinateProjection
    case humanOrderReorder
}
