import ExhaustTestSupport
@testable import ExhaustCore

/// Rebuilds a scalar or single-leaf group from the proposal's complete metadata, so every lifted tree flattens to the proposed sequence.
func liftLeafProposal(_ prefix: ChoiceSequence, _ fallbackTree: ChoiceTree) -> ChoiceTree? {
    let values = prefix.compactMap(\.value)
    guard values.count == 1 else {
        return nil
    }
    let value = values[0]
    let tree = ChoiceTree.choice(value.choice, .init(
        validRange: value.validRange,
        isRangeExplicit: value.isRangeExplicit
    ))
    switch fallbackTree {
        case .group:
            return .group([tree])
        default:
            return tree
    }
}

/// Builds a terminal search on the actual lifted graph, retaining the fixture's minimization operation and priority.
func liftedLeafScope(_ lifted: LiftResult, parent: EncoderInput) -> EncoderInput {
    EncoderInput(
        transformation: parent.transformation,
        baseSequence: lifted.sequence,
        tree: lifted.tree,
        graph: ChoiceGraph.build(from: lifted.tree),
        warmStartRecords: [:]
    )
}

/// Searches the lifted leaf using acceptance feedback rather than treating the proposal as already failing.
func binaryLeafStage(_: LiftProposal, lifted: LiftResult, parent: EncoderInput) -> DownstreamBuild {
    .stage(encoder: .binarySearch(GraphBinarySearchEncoder()), scope: liftedLeafScope(lifted, parent: parent))
}
