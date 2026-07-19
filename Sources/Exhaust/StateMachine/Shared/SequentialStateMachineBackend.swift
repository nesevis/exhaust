import ExhaustCore

/// Runs spec probes sequentially where all markers are `.prefix`.
///
/// Used when the spec's execution model is sequential (no concurrency mode selected). The entry point injects a sync or async execution closure at construction time.
struct SequentialStateMachineBackend<Spec: StateMachineSpecBase>: StateMachineBackend {
    let property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool
    let finalize: ([(ScheduleMarker, Spec.Command)]) -> (trace: [TraceStep], systemUnderTest: Spec.SystemUnderTest, failureDescription: String?)

    func probe(
        _ candidate: [(ScheduleMarker, Spec.Command)],
        context _: StateMachineRunContext<Spec>
    ) -> ProbeOutcome {
        property(candidate) ? .pass : .fail
    }

    func reduce(
        taggedCommands: [(ScheduleMarker, Spec.Command)],
        tree: ChoiceTree,
        context: StateMachineRunContext<Spec>
    ) -> StateMachineReduction<Spec.Command> {
        let config = Interpreters.ReducerConfiguration(
            maxStalls: 2,
            wallClockDeadlineNanoseconds: context.reductionDeadlineNanoseconds,
            enabledEncoders: [.laneCollapse, .deletion, .valueSearch, .floatSearch],
            tuning: SchedulerTuning(relaxMaterializationBudget: 0)
        )
        let (reduced, stats, _) = __ExhaustRuntime.reduceStateMachineCounterexample(
            value: taggedCommands,
            tree: tree,
            generator: context.state.sequenceGen,
            config: config,
            property: property
        )
        return StateMachineReduction(finalInput: reduced, stats: stats, timedOut: false)
    }

    func buildResult(
        reduced: [(ScheduleMarker, Spec.Command)],
        originalCommands: [Spec.Command]?,
        seed: UInt64?,
        iteration: Int,
        discoveryMethod: StateMachineDiscoveryMethod,
        context: StateMachineRunContext<Spec>
    ) -> (result: StateMachineResult<Spec>, issueMessage: String) {
        let outcome = finalize(reduced)
        let commands = reduced.map(\.1)
        let replaySeed = discoveryMethod.encodeReplaySeed(seed: seed, iteration: iteration)

        let result = StateMachineResult<Spec>(
            commands: commands,
            originalCommands: originalCommands,
            trace: outcome.trace,
            systemUnderTest: outcome.systemUnderTest,
            seed: discoveryMethod.resultSeed(seed),
            replaySeed: replaySeed,
            discoveryMethod: discoveryMethod
        )

        let issueMessage: String = context.config.suppress.issueReporting
            ? ""
            : __ExhaustRuntime.renderFailure(
                result,
                failureInfo: __ExhaustRuntime.StateMachineFailureInfo(
                    originalCommands: originalCommands,
                    discoveryMethod: discoveryMethod
                ),
                failureDescription: outcome.failureDescription
            )

        return (result, issueMessage)
    }
}
