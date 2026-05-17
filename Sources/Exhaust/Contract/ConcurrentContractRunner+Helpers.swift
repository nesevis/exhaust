// Spec state capture and skip pruning for concurrent contract testing.
import ExhaustCore

// MARK: - Spec State Capture

/// Replays a tagged command sequence sequentially on a fresh spec to capture the model and SUT descriptions at the point of failure.
///
/// Runs all commands as prefix (ignoring lane assignments) so the model state reflects the full sequence in array order. Returns the spec's ``modelDescription`` and ``systemUnderTest`` from the diverged state.
func captureSpecState<Spec: AsyncContractSpec>(
    taggedCommands: [(ScheduleMarker, Spec.Command)],
    specInit: () -> Spec
) -> (modelDescription: String, systemUnderTest: Spec.SystemUnderTest) {
    let commands = taggedCommands.map(\.1)
    let spec = SendableBox(specInit())
    let runQueue = RunQueue(laneCount: 1)
    let executor = LaneExecutor(lane: LaneID(index: 0), runQueue: runQueue)
    let done = SendableBox(false)

    Task(executorPreference: executor) { @Sendable [spec] in
        for command in commands {
            do {
                try await spec.value.run(command)
                try await spec.value.checkInvariants()
            } catch {
                break
            }
        }
        done.value = true
    }

    while done.value == false {
        guard let (_, job) = runQueue.dequeue(preferring: LaneID(index: 0)) else { continue }
        job.runSynchronously(on: executor.asUnownedTaskExecutor())
    }

    return (modelDescription: spec.value.modelDescription, systemUnderTest: spec.value.systemUnderTest)
}

// MARK: - Skip Pruning

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
