import Foundation

package extension __ExhaustRuntime {
    /// Builds the generator and property hooks for a sequential spec under `time:` mode.
    ///
    /// The returned adapter is ready for `runExploreTimeCore`: the generator emits tagged command sequences, the property maps outcomes to verdicts, and the hooks carry the spec's skip pruning and reduction. The caller supplies the time budget, settings, and configuration overrides.
    static func buildSequentialSpecAdapter<Spec: StateMachineSpec>(
        _: Spec.Type,
        commandLimit: Int? = nil
    ) -> SpecFuzzAdapter<SpecCandidateValue<Spec>> {
        buildSequentialAdapter(
            Spec.self,
            commandLimit: commandLimit,
            verdictProperty: syncSequentialVerdictProperty(Spec.self),
            identifySkips: { candidate in
                Spec.identifySkips(setupStep: candidate.setupStep, commands: candidate.taggedCommands.map(\.1))
            }
        )
    }

    /// Builds the generator and property hooks for an async `.sequential` spec under `time:` mode.
    ///
    /// The async twin of ``buildSequentialSpecAdapter(_:commandLimit:)``: the same tagged sequence shape, skip pruning, and property-only reduction, with the executor loop bridged through `blockingAwait`. The blocking bridge is safe here because the fuzz loop owns a GCD lane; the cooperative pool runs the awaited commands while the lane waits.
    static func buildAsyncSequentialSpecAdapter<Spec: AsyncStateMachineSpec>(
        _: Spec.Type,
        commandLimit: Int? = nil
    ) -> SpecFuzzAdapter<SpecCandidateValue<Spec>> {
        nonisolated(unsafe) let specInit: () -> Spec = { Spec() }
        let asyncSkipIdentifier = Spec.skipIdentifier(specInit: specInit)
        return buildSequentialAdapter(
            Spec.self,
            commandLimit: commandLimit,
            verdictProperty: asyncSequentialVerdictProperty(specInit: specInit),
            identifySkips: { candidate in
                asyncSkipIdentifier(candidate.setupStep, candidate.taggedCommands.map(\.1))
            }
        )
    }

    /// The one sequential adapter body: the sync and async forms differ only in how the executor loop is invoked and how skips are identified, so both hand those two closures here and share the generator, the prune hook, and the reduction.
    ///
    /// The verdict property drives the runner and carries the thrown error as the failure symptom; the Bool probe pruning and reduction use is derived from it, so the two can never disagree on what passes. Reduction is the value path's with the spec deadline: a spec reduction probe replays a whole command sequence against a fresh system under test, so it gets more wall clock per candidate.
    private static func buildSequentialAdapter<Spec: StateMachineSpecBase>(
        _: Spec.Type,
        commandLimit: Int?,
        verdictProperty: @escaping @Sendable (SpecCandidateValue<Spec>) -> FuzzVerdict,
        identifySkips: @escaping @Sendable (SpecCandidateValue<Spec>) -> Set<Int>
    ) -> SpecFuzzAdapter<SpecCandidateValue<Spec>> {
        let taggedSequenceGen = taggedSequenceGenerator(
            commandGen: Spec.commandGenerator,
            commandLimit: commandLimit ?? FuzzTunables.specDefaultCommandLimit
        )
        let candidateGen = specCandidateGenerator(Spec.self, sequenceGen: taggedSequenceGen)
        let rawProperty: @Sendable (SpecCandidateValue<Spec>) -> Bool = { candidate in
            verdictProperty(candidate).isFailure == false
        }
        let pruneHook = specTimePruneHook(
            sequenceGen: taggedSequenceGen,
            rawProperty: rawProperty,
            identifySkips: identifySkips
        )
        let reduceStrategy = FuzzRunner.propertyOnlyReduceStrategy(
            gen: candidateGen,
            property: verdictProperty,
            reducerConfiguration: Interpreters.ReducerConfiguration(
                maxStalls: 2,
                wallClockDeadlineNanoseconds: FuzzTunables.specReductionDeadlineNanoseconds
            )
        )
        return SpecFuzzAdapter(
            generator: candidateGen,
            property: verdictProperty,
            hooks: FuzzHooks(prune: pruneHook, reduceStrategy: reduceStrategy)
        )
    }

    /// Builds the `time:` mode prune hook: decomposes the candidate, prunes skipped commands on the command child, and recomposes.
    ///
    /// The decomposition keeps the setup subtree out of `pruneSequenceElements`' reach: without it, a setup containing an array generator would put a `.sequence` node ahead of the command sequence and skip pruning would silently delete setup choices. seed 0 is safe here: skip pruning is pure element deletion into a fully populated tree, so the guided fallback tree is authoritative and the seed fills no gaps.
    static func specTimePruneHook<Spec: StateMachineSpecBase>(
        sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>,
        rawProperty: @escaping @Sendable (SpecCandidateValue<Spec>) -> Bool,
        identifySkips: @escaping @Sendable (SpecCandidateValue<Spec>) -> Set<Int>
    ) -> @Sendable (SpecCandidateValue<Spec>, ChoiceTree) -> (value: SpecCandidateValue<Spec>, tree: ChoiceTree) {
        { value, tree in
            let setupTree: ChoiceTree?
            let commandTree: ChoiceTree
            if value.setupStep == nil {
                setupTree = nil
                commandTree = tree
            } else if let split = splitCandidateTree(tree) {
                setupTree = split.setupTree
                commandTree = split.commandTree
            } else {
                return (value, tree)
            }

            let setupStep = value.setupStep
            let pruned = pruneSkippedCommands(
                value: value.taggedCommands,
                tree: commandTree,
                generator: sequenceGen,
                seed: 0,
                property: { commands in
                    rawProperty(SpecCandidateValue(setupStep: setupStep, taggedCommands: commands))
                },
                identifySkips: { commands in
                    identifySkips(SpecCandidateValue(setupStep: setupStep, taggedCommands: commands))
                },
                requireFailurePreserved: false,
                logEvent: "spec_time_prune"
            )
            let prunedValue = SpecCandidateValue<Spec>(setupStep: setupStep, taggedCommands: pruned.value)
            let prunedTree = setupTree.map { composeCandidateTree(setupTree: $0, commandTree: pruned.tree) } ?? pruned.tree
            return (prunedValue, prunedTree)
        }
    }
}

// MARK: - Cooperative Adapter

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
package extension __ExhaustRuntime {
    /// What a `.tasks` run's probes count and cannot return.
    ///
    /// A verdict or reduction probe reaches the runner only through its return value, which carries the outcome for the input and nothing about the run, so the counts a stall produces travel on one reference the closures capture. One object rather than a box each: the next counter is a field, not another parameter threaded through the adapter.
    ///
    /// @unchecked: every write happens inside a probe on the fuzz loop's own lane, and the run reads it after the loop returns.
    final class TasksRunTelemetry: @unchecked Sendable {
        /// Interleaving searches that ran out of replay budget. A box of its own because `drainAndJudge` takes one.
        package let searchAbandonments = UnsafeSendableBox(0)

        /// Probes whose drain timed out, either disposition.
        package var stalledSearches = 0

        package init() {}
    }

    /// Builds the generator and property hooks for a `.tasks` spec under `time:` mode.
    ///
    /// Unlike the sequential adapters, the generator draws a lane-assigning schedule marker as a choice ahead of each command (``zipScheduleMarker(onto:concurrencyLevel:)``), so the interleaving is searchable input: the byte mutators that move commands between lanes and reorder the schedule are the same ones that mutate command arguments, and reduction minimizes markers toward the sequential prefix. The property drains each sequence through the cooperative scheduler at the marker-directed interleaving.
    ///
    /// A timed-out drain is inconclusive, not a counterexample, and how it is inconclusive matters. A probe whose cancellation drain completed left nothing running: the attempt is counted and dropped, and the corpus never sees it, because its coverage describes the stall rather than the input. A probe whose work escaped cancellation is still executing the system under test and still recording coverage, so its verdict is ``FuzzVerdict/escaped`` and the runner ends the run on it — everything after it would measure some of the escaped attempt. Reduction aborts on either, so a counterexample never reduces toward a hang; an escape there comes back on ``FuzzReductionResult/escaped``.
    ///
    /// - Returns: Nil when the spec's command generator is not a top-level pick, which schedule-marker tagging requires.
    /// - Parameters:
    ///   - idleTimeoutMilliseconds: The drain loop's stall bound. Defaults to the plain-`#execute` default; tests lower it so stall-path assertions do not wait out two seconds per evaluation.
    ///   - telemetry: What the probes count but cannot return. A verdict closure's only channel to the runner is its return value, which describes the input, so run-level counts travel here.
    static func buildTasksSpecAdapter<Spec: AsyncStateMachineSpec>(
        _: Spec.Type,
        commandLimit: Int? = nil,
        concurrencyLevel: Int,
        idleTimeoutMilliseconds: Int = ResolvedConcurrentConfig.defaultIdleTimeout,
        telemetry: TasksRunTelemetry = TasksRunTelemetry()
    ) -> SpecFuzzAdapter<SpecCandidateValue<Spec>>? {
        guard let taggedCommandGen = zipScheduleMarker(
            onto: Spec.commandGenerator.gen,
            concurrencyLevel: concurrencyLevel
        ) else {
            return nil
        }
        // A spec that declares an equivalence pays for an interleaving search on every probe the equivalence rejects, and that search grows multinomially in the sequence length. The plain runner drops to the thread-based default for exactly this reason; `FuzzTunables.specDefaultCommandLimit` is sized for accumulation faults on sequences nothing searches, and at that length an equivalence-bearing spec abandons its searches instead of judging them.
        let resolvedCommandLimit = commandLimit
            ?? (Spec.hasEquivalence ? ConcurrentSpecTunables.defaultCommandLimit : FuzzTunables.specDefaultCommandLimit)
        let sequenceGen = Gen.arrayOf(
            taggedCommandGen,
            within: 1 ... UInt64(resolvedCommandLimit),
            scaling: .constant
        )
        let candidateGen = specCandidateGenerator(Spec.self, sequenceGen: sequenceGen)

        nonisolated(unsafe) let specInit: () -> Spec = { Spec() }

        // Abandonments are tallied on the discovery path only. A run that keeps abandoning its searches passes probes it never judged, which is the one thing a green fuzz report must not hide; counting the reduction probes as well would inflate the figure with re-judgements of a sequence already counted.
        let verdictProperty: @Sendable (SpecCandidateValue<Spec>) -> FuzzVerdict = { candidate in
            let result = CooperativeScheduler.drainAndJudge(
                taggedCommands: candidate.taggedCommands,
                setupStep: candidate.setupStep,
                specInit: specInit,
                concurrencyLevel: concurrencyLevel,
                recordTrace: false,
                idleTimeoutMilliseconds: idleTimeoutMilliseconds,
                searchAbandonments: telemetry.searchAbandonments
            )
            switch result.disposition {
                case .completed:
                    break
                case .timedOutQuiesced:
                    telemetry.stalledSearches += 1
                    return .inconclusive
                case .timedOutEscaped:
                    telemetry.stalledSearches += 1
                    return .escaped
            }
            if result.passed {
                return .pass
            }
            return .fail(FailureSymptom(kind: result.failureSymptomKind ?? "returnedFalse"))
        }
        let rawProperty: @Sendable (SpecCandidateValue<Spec>) -> Bool = { candidate in
            verdictProperty(candidate).isFailure == false
        }

        let rawIdentifySkips = Spec.skipIdentifier(specInit: specInit)
        let identifySkips: @Sendable (SpecCandidateValue<Spec>) -> Set<Int> = { candidate in
            rawIdentifySkips(candidate.setupStep, candidate.taggedCommands.map(\.1))
        }

        let pruneHook = specTimePruneHook(
            sequenceGen: sequenceGen,
            rawProperty: rawProperty,
            identifySkips: identifySkips
        )

        // Two-pass reduction (lane collapse + deletion, then value minimization), run inline on the fuzz loop's GCD lane. The drain loop's spin-polling stays off the cooperative pool because the loop's lane hosts it, which is what inline reduction guarantees by construction. Unlike the plain-#execute machine, `time:` mode reduces the whole candidate in one tree, so setup values minimize alongside the commands here rather than in a separate pass.
        let reduceStrategy: @Sendable (ChoiceTree, SpecCandidateValue<Spec>, FailureSymptom, ProbeWrapper?) -> FuzzReductionResult<SpecCandidateValue<Spec>> = { tree, value, _, probeWrapper in
            // The reducer's probe verdict has no escape case, so the probe leaves it here for the result to carry.
            let escaped = UnsafeSendableBox(false)
            let probeProperty: @Sendable (SpecCandidateValue<Spec>) -> StateMachineProbeVerdict<Void> = { candidate in
                let result = CooperativeScheduler.drainAndJudge(
                    taggedCommands: candidate.taggedCommands,
                    setupStep: candidate.setupStep,
                    specInit: specInit,
                    concurrencyLevel: concurrencyLevel,
                    recordTrace: false,
                    idleTimeoutMilliseconds: idleTimeoutMilliseconds
                )
                switch result.disposition {
                    case .completed:
                        break
                    case .timedOutQuiesced:
                        // Not a counterexample. Abort further reduction and keep the failure as-is rather than reducing toward a hang.
                        ExhaustLog.notice(category: .reducer, event: "spec_time_reduction_timeout")
                        return .abort
                    case .timedOutEscaped:
                        // Work that escaped cancellation contaminates the run whichever probe leaked it: it keeps executing the system under test and keeps recording coverage against every later attempt. Reduction aborts as above, and the run ends for the same reason a search-phase escape ends it.
                        ExhaustLog.notice(category: .reducer, event: "spec_time_reduction_timeout")
                        escaped.value = true
                        return .abort
                }
                return result.passed ? .pass : .fail(())
            }
            let result = reduceConcurrentTwoPass(
                generator: candidateGen,
                tree: tree,
                output: value,
                deadlineNanoseconds: FuzzTunables.specReductionDeadlineNanoseconds,
                probeWrapper: probeWrapper,
                property: probeProperty
            )
            return FuzzReductionResult(
                sequence: result.sequence,
                tree: result.tree,
                value: result.value,
                propertyInvocations: result.stats.reductionProbesWherePropertyPassed
                    + result.stats.reductionProbesWherePropertyFailed,
                escaped: escaped.value
            )
        }

        return SpecFuzzAdapter(
            generator: candidateGen,
            property: verdictProperty,
            hooks: FuzzHooks(prune: pruneHook, reduceStrategy: reduceStrategy)
        )
    }
}

// MARK: - Adapter Type

/// Bundles the generator and property hooks for one spec type under `time:` mode.
package struct SpecFuzzAdapter<Output> {
    /// Generates tagged command sequences for the runner.
    package let generator: Generator<Output>
    /// Maps a command-sequence outcome to a pass or fail verdict.
    package let property: @Sendable (Output) -> FuzzVerdict
    /// The spec's skip pruning and reduction, carried into ``FuzzRunner`` as one unit.
    package let hooks: FuzzHooks<Output>
}
