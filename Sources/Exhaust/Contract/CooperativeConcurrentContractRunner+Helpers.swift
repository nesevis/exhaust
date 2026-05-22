// Skip pruning and sequential oracle for concurrent contract testing.
import ExhaustCore

// MARK: - Sequential Oracle

/// Captures the SUT and model state after a sequential (race-free) replay of the failing command sequence. Provides the "expected" baseline in failure reports so the user can see what the system should have produced without the interleaving.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
struct SequentialOracleResult<Spec: AsyncContractSpec> {
    var systemUnderTest: Spec.SystemUnderTest
    var modelDescription: String
    var sutDescription: String
}

/// Runs the command sequence sequentially on a fresh spec and returns the expected state if all invariants pass.
///
/// Provides the "expected" state in the failure report — what the system should have produced without the race. If the sequential replay also fails, returns nil (the bug exists even without concurrency).
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
func sequentialOracle<Spec: AsyncContractSpec>(
    commands: [Spec.Command],
    specInit: () -> Spec,
    idleTimeoutMilliseconds: Int = 1000
) -> SequentialOracleResult<Spec>? {
    let spec = UnsafeSendableBox(specInit())
    let runQueue = RunQueue(laneCount: 1)
    let executor = LaneExecutor(lane: LaneID(index: 0), runQueue: runQueue)
    let passed = UnsafeSendableBox(true)
    let done = UnsafeSendableBox(false)
    let idleTimeout: Duration = .milliseconds(idleTimeoutMilliseconds)

    Task(executorPreference: executor) { @Sendable [spec] in
        for command in commands {
            do {
                try await spec.value.run(command)
                try await spec.value.checkInvariants()
            } catch {
                passed.value = false
                break
            }
        }
        done.value = true
    }

    var lastActivity = ContinuousClock.now
    while done.value == false {
        guard let (_, job) = runQueue.dequeue(preferring: LaneID(index: 0)) else {
            if ContinuousClock.now - lastActivity > idleTimeout { return nil }
            continue
        }
        job.runSynchronously(on: executor.asUnownedTaskExecutor())
        lastActivity = ContinuousClock.now
    }

    guard passed.value else { return nil }
    return SequentialOracleResult(
        systemUnderTest: spec.value.systemUnderTest,
        modelDescription: spec.value.modelDescription,
        sutDescription: "\(spec.value.systemUnderTest)"
    )
}

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
