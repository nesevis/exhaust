// Skip pruning and sequential oracle for concurrent contract testing.
import ExhaustCore

// MARK: - Sequential Oracle

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
extension __ExhaustRuntime {
    /// Captures the SUT and model state after a sequential (race-free) replay of the failing command sequence. Provides the "expected" baseline in failure reports so the user can see what the system should have produced without the interleaving.
    struct SequentialOracleResult<Spec: AsyncContractSpec> {
        var systemUnderTest: Spec.SystemUnderTest
        var modelDescription: String
        var sutDescription: String
    }

    /// Runs the command sequence sequentially on a fresh spec and returns the expected state if all invariants pass.
    ///
    /// Provides the "expected" state in the failure report — what the system should have produced without the race. If the sequential replay also fails, returns nil (the bug exists even without concurrency).
    static func sequentialOracle<Spec: AsyncContractSpec>(
        commands: [Spec.Command],
        specInit: () -> Spec,
        idleTimeoutMilliseconds: Int = 1000
    ) -> SequentialOracleResult<Spec>? {
        let spec = UnsafeSendableBox(specInit())
        let runQueue = RunQueue(laneCount: 1)
        let executor = LaneExecutor(lane: LaneID(index: 0), runQueue: runQueue)
        let passed = UnsafeSendableBox(true)
        let done = UnsafeSendableBox(false)
        let oracleResult = UnsafeSendableBox<SequentialOracleResult<Spec>?>(nil)
        Task(executorPreference: executor) { @Sendable [spec, oracleResult] in
            for command in commands {
                do {
                    try await spec.value.run(command)
                    try await spec.value.checkInvariants()
                } catch {
                    passed.value = false
                    break
                }
            }
            if passed.value {
                oracleResult.value = SequentialOracleResult(
                    systemUnderTest: spec.value.systemUnderTest,
                    modelDescription: spec.value.modelDescription,
                    sutDescription: "\(spec.value.systemUnderTest)"
                )
            }
            done.value = true
        }

        var idleStopwatch = Stopwatch()
        while done.value == false {
            guard let (_, job) = runQueue.dequeue(preferring: LaneID(index: 0)) else {
                if idleStopwatch.elapsedMilliseconds > Double(idleTimeoutMilliseconds) { return nil }
                continue
            }
            job.runSynchronously(on: executor.asUnownedTaskExecutor())
            idleStopwatch = Stopwatch()
        }

        return oracleResult.value
    }
}

// MARK: - Skip Pruning

extension __ExhaustRuntime {
    /// Identifies skipped commands and prunes them from the choice tree, returning a shorter value and tree that still fail the property.
    ///
    /// Runs the command sequence through the skip identifier (which executes sequentially on a fresh spec) to find commands whose preconditions are not met. If any are found, those elements are removed from the tree, the tree is rematerialized, and the property is re-checked. If the pruned sequence still fails, the pruned value and tree are returned; otherwise the originals are returned unchanged.
    static func pruneSkippedCommands<Value: Collection>(
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
            metadata: [
                "total_commands": "\(value.count)",
                "skipped_count": "\(skippedIndices.count)",
                "skipped_indices": "\(skippedIndices.sorted())",
                "remaining": "\(value.count - skippedIndices.count)",
            ]
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

    /// Runs the choice-graph reducer and unwraps its outcome to the reduced value, or the input unchanged when the reducer makes no improvement or fails to run.
    ///
    /// Shared by the sequential SCA failure tail and the concurrent counterexample reducer. Logging stays with each caller — they emit different events — so this is a pure reduce-and-unwrap. `reduced` is `true` only when the reducer produced a strictly simpler value.
    static func reduceContractCounterexample<Value>(
        value: Value,
        tree: ChoiceTree,
        generator: Generator<Value>,
        config: Interpreters.ReducerConfiguration,
        property: @escaping @Sendable (Value) -> Bool
    ) -> (value: Value, stats: ReductionStats?, reduced: Bool) {
        guard let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: tree,
            output: value,
            config: config,
            property: property
        ) else {
            return (value, nil, false)
        }
        if case let .reduced(_, reduced) = result.outcome {
            return (reduced, result.stats, true)
        }
        return (value, result.stats, false)
    }
}
