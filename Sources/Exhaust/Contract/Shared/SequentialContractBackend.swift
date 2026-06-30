import ExhaustCore

/// Runs contract probes sequentially where all markers are `.prefix`.
///
/// Sync versus async spec bridging is handled by the entry point, which injects the appropriate execution closure at construction time.
struct SequentialContractBackend<Spec: ContractSpecBase>: ContractBackend {
    let property: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Bool
    let finalize: ([(ScheduleMarker, Spec.Command)]) -> (trace: [TraceStep], systemUnderTest: Spec.SystemUnderTest, failureDescription: String?)

    func probe(
        _ candidate: [(ScheduleMarker, Spec.Command)],
        context _: ContractRunContext<Spec>
    ) -> ProbeOutcome {
        property(candidate) ? .pass : .fail
    }

    func reduce(
        taggedCommands: [(ScheduleMarker, Spec.Command)],
        tree: ChoiceTree,
        context: ContractRunContext<Spec>
    ) -> ContractReduction<Spec.Command> {
        let config = Interpreters.ReducerConfiguration(
            maxStalls: 2,
            wallClockDeadlineNanoseconds: context.reductionDeadlineNanoseconds,
            enabledEncoders: [.laneCollapse, .deletion, .valueSearch, .floatSearch],
            tuning: SchedulerTuning(relaxMaterializationBudget: 0)
        )
        let (reduced, stats, _) = __ExhaustRuntime.reduceContractCounterexample(
            value: taggedCommands,
            tree: tree,
            generator: context.sequenceGen,
            config: config,
            property: property
        )
        return ContractReduction(finalInput: reduced, stats: stats, timedOut: false)
    }

    func buildResult(
        reduced: [(ScheduleMarker, Spec.Command)],
        originalCommands: [Spec.Command]?,
        seed: UInt64?,
        iteration: Int,
        discoveryMethod: ContractDiscoveryMethod,
        context: ContractRunContext<Spec>
    ) -> (result: ContractResult<Spec>, issueMessage: String) {
        let outcome = finalize(reduced)
        let commands = reduced.map(\.1)
        let replaySeed = discoveryMethod.encodeReplaySeed(seed: seed, iteration: iteration)

        let result = ContractResult<Spec>(
            status: .fail,
            commands: commands,
            originalCommands: originalCommands,
            trace: outcome.trace,
            systemUnderTest: outcome.systemUnderTest,
            seed: discoveryMethod.resultSeed(seed),
            replaySeed: replaySeed,
            discoveryMethod: discoveryMethod
        )

        let issueMessage: String = context.config.suppressIssueReporting
            ? ""
            : __ExhaustRuntime.renderFailure(
                result,
                failureInfo: __ExhaustRuntime.ContractFailureInfo(
                    originalCommands: originalCommands,
                    discoveryMethod: discoveryMethod
                ),
                failureDescription: outcome.failureDescription
            )

        return (result, issueMessage)
    }
}
