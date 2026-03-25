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
    // Closed reductions
    case structuralIsolation
    case oscillationDamping
    case humanOrderReorder
}
