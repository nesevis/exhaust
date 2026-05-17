// Skip pruning for concurrent contract testing.
import ExhaustCore

/// Identifies skipped commands and prunes them from the choice tree, returning a shorter value and tree that still fail the property.
///
/// Runs the command sequence through the skip identifier (which executes sequentially on a fresh spec) to find commands whose preconditions are not met. If any are found, those elements are removed from the tree, the tree is rematerialized, and the property is re-checked. If the pruned sequence still fails, the pruned value and tree are returned; otherwise the originals are returned unchanged.
func pruneSkippedCommands<Value>(
    value: Value,
    tree: ChoiceTree,
    generator: Generator<Value>,
    seed: UInt64,
    property: @Sendable (Value) -> Bool,
    identifySkips: (Value) -> Set<Int>,
    logEvent: String
) -> (value: Value, tree: ChoiceTree) {
    let skippedIndices = identifySkips(value)
    guard skippedIndices.isEmpty == false else {
        return (value, tree)
    }

    ExhaustLog.notice(
        category: .reducer,
        event: logEvent,
        metadata: ["skipped_count": "\(skippedIndices.count)"]
    )
    let prunedTree = pruneSequenceElements(from: tree, at: skippedIndices)
    let prunedSequence = ChoiceSequence.flatten(prunedTree)
    let prunedMode = Materializer.Mode.guided(seed: seed, fallbackTree: nil)
    if case let .success(rematerialized, rematerializedTree, _) = Materializer.materialize(
        generator, prefix: prunedSequence, mode: prunedMode, fallbackTree: prunedTree
    ),
        property(rematerialized) == false
    {
        return (rematerialized, rematerializedTree)
    }
    return (value, tree)
}
