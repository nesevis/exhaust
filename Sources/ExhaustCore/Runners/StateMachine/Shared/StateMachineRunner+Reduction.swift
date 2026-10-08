// Reduction and skip-aware pruning shared by the spec backends.
import Foundation

package extension __ExhaustRuntime {
    /// Removes elements at the given indices from `.sequence` nodes in the choice tree.
    ///
    /// Walks the tree recursively, pruning indexed elements from the first sequence node encountered and updating its stored length. Used by the skip-pruning pass to excise commands whose preconditions were not met before handing the tree to the reducer.
    static func pruneSequenceElements(
        from tree: ChoiceTree,
        at indices: Set<Int>
    ) -> ChoiceTree {
        switch tree {
            case let .sequence(elements, metadata):
                let pruned = elements.enumerated()
                    .filter { indices.contains($0.offset) == false }
                    .map(\.element)
                return .sequence(elements: pruned, metadata: metadata)
            case let .group(children, isOpaque, _):
                guard let targetIndex = children.firstIndex(where: { containsSequence($0) }) else {
                    return tree
                }
                var updated = children
                updated[targetIndex] = pruneSequenceElements(from: updated[targetIndex], at: indices)
                return .group(updated, isOpaque: isOpaque)
            case let .resize(newSize, choices):
                guard let targetIndex = choices.firstIndex(where: { containsSequence($0) }) else {
                    return tree
                }
                var updated = choices
                updated[targetIndex] = pruneSequenceElements(from: updated[targetIndex], at: indices)
                return .resize(newSize: newSize, choices: updated)
            default:
                return tree
        }
    }

    private static func containsSequence(_ tree: ChoiceTree) -> Bool {
        switch tree {
            case .sequence:
                return true
            case let .group(children, _, _):
                return children.contains(where: { containsSequence($0) })
            case let .resize(_, choices):
                return choices.contains(where: { containsSequence($0) })
            default:
                return false
        }
    }
}

package extension __ExhaustRuntime {
    /// Identifies skipped commands and prunes them from the choice tree, returning a shorter value and tree.
    ///
    /// Runs the command sequence through the skip identifier (which executes sequentially on a fresh spec) to find commands whose preconditions are not met. If any are found, those elements are removed from the tree and the tree is rematerialized. When `requireFailurePreserved` is `true`, the rematerialized value is returned only if it still fails the property; otherwise the originals are returned unchanged. When `false`, the rematerialized value is returned whenever materialization succeeds, without re-checking the property.
    ///
    /// - Parameter requireFailurePreserved: Whether to re-check that the pruned sequence still fails the property before returning it. The counterexample-reduction callers keep this `true`. The `#explore(Spec.self, time:)` prune hook passes `false` because it normalizes every admitted candidate rather than only counterexamples, and skip pruning is pure element deletion into a fully populated tree, so a failing candidate keeps failing.
    static func pruneSkippedCommands<Value: Collection>(
        value: Value,
        tree: ChoiceTree,
        generator: Generator<Value>,
        seed: UInt64,
        property: @Sendable (Value) -> Bool,
        identifySkips: (Value) -> Set<Int>,
        requireFailurePreserved: Bool = true,
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
        let prunedMode = Materializer.Mode.guided(seed: seed, fallbackTree: prunedTree)
        if case let .success(rematerialized, rematerializedTree, _) = Materializer.materialize(
            generator, context: .init(
                prefix: prunedSequence, mode: prunedMode
            )
        ) {
            if requireFailurePreserved == false || property(rematerialized) == false {
                return (rematerialized, rematerializedTree)
            }
        }
        return (value, tree)
    }

    /// Runs the reducer and unwraps its outcome to the reduced value, or the input unchanged when the reducer makes no improvement or fails to run.
    ///
    /// Shared by the sequential SCA failure tail and the concurrent counterexample reducer. Logging stays with each caller (they emit different events), so this is a pure reduce-and-unwrap. `reduced` is `true` only when the reducer produced a strictly simpler value.
    static func reduceStateMachineCounterexample<Value>(
        value: Value,
        tree: ChoiceTree,
        generator: Generator<Value>,
        config: Interpreters.ReducerConfiguration,
        property: @escaping @Sendable (Value) -> Bool
    ) -> (value: Value, stats: ReductionStats, reduced: Bool) {
        let run = ReductionRunner.reduce(
            generator,
            tree: tree,
            value: value,
            configuration: config,
            property: property
        )
        return (run.improved ? run.value : value, run.stats, run.improved)
    }

    /// Reduces a concurrent spec counterexample in two passes: structural (lane collapse + deletion) then value minimization.
    ///
    /// Lane collapse and deletion run together in pass 1 so the scheduler can interleave them — collapsing a lane then deleting the now-prefix command in the same cycle, rather than over-collapsing before deletion gets a chance. Pass 2 runs value and float search, including convergence confirmation to reopen stale floors, on the structurally reduced sequence. Each pass rematerializes on success to keep the output and tree consistent. Shared by the cooperative and preemptive backends so the reduction strategy cannot drift between them.
    ///
    /// The property closure returns a ``StateMachineProbeVerdict`` so the preemptive backend can carry linearizability evidence (response witnesses, failure descriptions) through reduction without a separate side-channel. The cooperative backend returns `.fail(())`. A `.abort` verdict (a probe timed out, so further probing would reduce toward a hang) stops reduction: remaining probes in the current pass are treated as passing and the second pass is skipped, leaving the counterexample as-is.
    static func reduceConcurrentTwoPass<Value, Evidence>(
        generator: Generator<Value>,
        tree: ChoiceTree,
        output: Value,
        deadlineNanoseconds: UInt64,
        runDeadlineNanoseconds: UInt64? = nil,
        probeWrapper: ProbeWrapper? = nil,
        property: @escaping @Sendable (Value) -> StateMachineProbeVerdict<Evidence>
    ) -> ConcurrentTwoPassResult<Value, Evidence> {
        let noRelax = SchedulerTuning(relaxMaterializationBudget: 0, relaxImprovingProbeBudget: 0)
        var currentOutput = output
        var currentTree = tree
        // The reducer canonicalizes its sequence at init, so the sequence each pass returns is the one that reproduces its value through `.exact` materialization — re-flattening the tree afterwards is not guaranteed to. Track it so callers on the `(sequence, tree, value)` path get the authoritative one.
        var currentSequence = ChoiceSequence.flatten(tree)
        var mergedStats = ReductionStats()
        nonisolated(unsafe) var lastEvidence: Evidence?
        nonisolated(unsafe) var aborted = false

        // The underlying graph reducer has no abort channel, so an abort is latched here: remaining probes in the in-flight pass report passing (rejecting every candidate) without reaching the backend's property, and the next pass is skipped.
        let boolProperty: @Sendable (Value) -> Bool = { commands in
            guard aborted == false, runDeadlineNanoseconds.map({ MonotonicClock.nanoseconds() < $0 }) ?? true else {
                return true
            }
            switch property(commands) {
                case .pass:
                    return true
                case .abort:
                    aborted = true
                    return true
                case let .fail(evidence):
                    lastEvidence = evidence
                    return false
            }
        }

        // Pass 1: structural reduction (lane collapse + deletion).
        let structuralRun = ReductionRunner.reduce(
            generator,
            tree: currentTree,
            value: currentOutput,
            configuration: .init(
                maxStalls: 2,
                wallClockDeadlineNanoseconds: deadlineNanoseconds,
                enabledEncoders: [.laneCollapse, .deletion],
                tuning: noRelax,
                probeWrapper: probeWrapper
            ),
            runDeadlineNanoseconds: runDeadlineNanoseconds,
            property: boolProperty
        )
        if structuralRun.started {
            mergedStats.merge(structuralRun.stats)
        }
        if structuralRun.improved {
            currentOutput = structuralRun.value
            currentTree = structuralRun.tree
            currentSequence = structuralRun.sequence
            if case let .success(value, tree, _) = Materializer.materialize(
                generator, context: .init(
                    prefix: structuralRun.sequence, mode: .exact
                )
            ) {
                currentOutput = value
                currentTree = tree
            }
        }

        // Pass 2: value minimization on the structurally reduced sequence.
        if aborted == false {
            let valueRun = ReductionRunner.reduce(
                generator,
                tree: currentTree,
                value: currentOutput,
                configuration: .init(
                    maxStalls: 2,
                    wallClockDeadlineNanoseconds: deadlineNanoseconds,
                    enabledEncoders: [.valueSearch, .floatSearch, .convergenceConfirmation],
                    tuning: noRelax,
                    probeWrapper: probeWrapper
                ),
                runDeadlineNanoseconds: runDeadlineNanoseconds,
                property: boolProperty
            )
            if valueRun.started {
                mergedStats.merge(valueRun.stats)
            }
            if valueRun.improved {
                currentOutput = valueRun.value
                currentTree = valueRun.tree
                currentSequence = valueRun.sequence
                if case let .success(value, tree, _) = Materializer.materialize(
                    generator, context: .init(
                        prefix: valueRun.sequence, mode: .exact
                    )
                ) {
                    currentOutput = value
                    currentTree = tree
                }
            }
        }

        return ConcurrentTwoPassResult(
            value: currentOutput,
            tree: currentTree,
            sequence: currentSequence,
            stats: mergedStats,
            lastEvidence: lastEvidence,
            aborted: aborted
        )
    }
}

package extension __ExhaustRuntime {
    enum StateMachineProbeVerdict<Evidence> {
        case pass
        case fail(Evidence)
        /// The probe could not produce a verdict (it timed out) and further probing would reduce toward a hang. ``reduceConcurrentTwoPass(generator:tree:output:deadlineNanoseconds:property:)`` stops reduction and keeps the counterexample as-is.
        case abort
    }

    struct ConcurrentTwoPassResult<Value, Evidence> {
        package let value: Value
        package let tree: ChoiceTree
        /// The reducer's own choice sequence for `value` — the one that reproduces it through `.exact` materialization. `ChoiceSequence.flatten(tree)` is not guaranteed to, because the reducer canonicalizes at init; consumers on the `(sequence, tree, value)` path must carry this instead of re-flattening.
        package let sequence: ChoiceSequence
        package let stats: ReductionStats
        package let lastEvidence: Evidence?
        /// Whether the property aborted reduction. Backends surface this as ``StateMachineReduction/timedOut``.
        package let aborted: Bool
    }
}
