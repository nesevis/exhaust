import ExhaustCore

/// Runs contract probes via preemptive concurrent execution on real GCD threads.
///
/// Generic over ``PreemptiveBackend``, which has synchronous (``PreemptiveChecker``) and async (``AsyncPreemptiveChecker``) conformers. The backend adapts the existing per-probe execution and linearizability checking into the ``ContractBackend`` protocol so the ``ContractMachine`` can drive the preemptive pipeline identically to the cooperative and sequential paths.
struct PreemptiveContractBackend<Inner: PreemptiveBackend>: ContractBackend {
    typealias Spec = Inner.Spec

    let inner: Inner
    let concurrencyLevel: Int

    // MARK: - Probe

    func probe(
        _ candidate: [(ScheduleMarker, Spec.Command)],
        context: ContractRunContext<Spec>
    ) -> ProbeOutcome {
        let partition = LanePartition(candidate)
        let outcome = inner.execute(candidate, partition: partition)
        if case .timedOut = outcome {
            return .timeout
        }
        if let evidence = __ExhaustRuntime.classifyFailure(
            taggedCommands: candidate,
            outcome: outcome,
            backend: inner
        ) {
            context.probeEvidence = evidence
            return .fail
        }
        return .pass
    }

    // MARK: - Reduce

    func reduce(
        taggedCommands: [(ScheduleMarker, Spec.Command)],
        tree: ChoiceTree,
        context: ContractRunContext<Spec>
    ) -> ContractReduction<Spec.Command> {
        let discoveryInvocations = context.invocationCounter.value
        let repetitions = PreemptiveReduction.confirmationRepetitions(discoveryIterations: discoveryInvocations)

        nonisolated(unsafe) let unsafeContext = context
        let linearizableProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> __ExhaustRuntime.ContractProbeVerdict<__ExhaustRuntime.FailureEvidence<Spec>> = { commands in
            unsafeContext.invocationCounter.value += 1
            let partition = LanePartition(commands)
            for _ in 0 ..< repetitions {
                if let evidence = __ExhaustRuntime.classifyFailure(
                    taggedCommands: commands,
                    outcome: inner.execute(commands, partition: partition),
                    backend: inner
                ) {
                    return .fail(evidence)
                }
            }
            return .pass
        }

        let twoPassResult = __ExhaustRuntime.reduceConcurrentTwoPass(
            generator: context.sequenceGen,
            tree: tree,
            output: taggedCommands,
            deadlineNanoseconds: context.reductionDeadlineNanoseconds,
            property: linearizableProperty
        )

        let reduced = twoPassResult.value.filter(\.0.isPrefix) + twoPassResult.value.filter { $0.0.isPrefix == false }

        if let cached = twoPassResult.lastEvidence {
            context.probeEvidence = cached
            return ContractReduction(finalInput: reduced, stats: twoPassResult.stats, timedOut: false)
        }

        let confirmed = __ExhaustRuntime.confirmRealFailure(
            backend: inner,
            input: reduced,
            discoveryIterations: discoveryInvocations
        )
        if let confirmed {
            context.probeEvidence = confirmed
        }
        return ContractReduction(finalInput: reduced, stats: twoPassResult.stats, timedOut: false)
    }

    // MARK: - Build Result

    func buildResult(
        reduced: [(ScheduleMarker, Spec.Command)],
        originalCommands: [Spec.Command]?,
        seed: UInt64?,
        iteration: Int,
        discoveryMethod: ContractDiscoveryMethod,
        context: ContractRunContext<Spec>
    ) -> (result: ContractResult<Spec>, issueMessage: String) {
        let replaySeed = discoveryMethod.encodeReplaySeed(seed: seed, iteration: iteration)

        let (replayResult, failureDescription) = inner.buildResult(
            reduced: reduced,
            originalCommands: originalCommands,
            seed: seed,
            replaySeed: replaySeed,
            discoveryMethod: discoveryMethod,
            timedOut: context.lastRunTimedOut
        )

        let systemUnderTest = context.probeEvidence?.outcome.concurrentSpec?.systemUnderTest ?? replayResult.systemUnderTest
        let result = ContractResult<Spec>(
            status: replayResult.status,
            commands: replayResult.commands,
            originalCommands: replayResult.originalCommands,
            trace: replayResult.trace,
            systemUnderTest: systemUnderTest,
            seed: replayResult.seed,
            replaySeed: replayResult.replaySeed,
            discoveryMethod: replayResult.discoveryMethod
        )

        context.failureContext.specName = "\(Spec.self)"
        context.failureContext.isPreemptive = true
        context.failureContext.discoveryMethod = discoveryMethod
        context.failureContext.replaySeed = replaySeed
        context.failureContext.timedOut = context.lastRunTimedOut
        context.failureContext.oracleDescription = failureDescription.map { "Expected state (from sequential replay):\n  \($0)" }

        if let evidence = context.probeEvidence {
            context.failureContext.failureDescription = (evidence.failureDescription ?? evidence.outcome.concurrentSpec?.failureDescription()).map { "Actual state (from concurrent execution):\n  \($0)" }
            context.failureContext.laneResponseValues = __ExhaustRuntime.laneResponseValues(from: evidence.outcome)
            context.failureContext.linearizabilityWitness = evidence.witness
        }

        let issueMessage: String = context.config.suppressIssueReporting
            ? ""
            : __ExhaustRuntime.renderPreemptiveFailure(reduced, context: context.failureContext)

        return (result, issueMessage)
    }
}
