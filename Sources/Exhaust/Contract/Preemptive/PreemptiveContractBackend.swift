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
        context _: ContractRunContext<Spec>
    ) -> ProbeOutcome {
        let partition = LanePartition(candidate)
        let outcome = inner.execute(candidate, partition: partition)
        if case .timedOut = outcome {
            return .timeout
        }
        // Evidence is established only by reduction and final confirmation, which run against the reduced sequence. Pruning probes run against pre-reduction sequences, so they must not leak their evidence into the final report.
        let isFailure = __ExhaustRuntime.classifyFailure(
            taggedCommands: candidate,
            outcome: outcome,
            backend: inner
        ) != nil
        return isFailure ? .fail : .pass
    }

    // MARK: - Reduce

    func reduce(
        taggedCommands: [(ScheduleMarker, Spec.Command)],
        tree: ChoiceTree,
        context: ContractRunContext<Spec>
    ) -> ContractReduction<Spec.Command> {
        let discoveryInvocations = context.invocationCounter.value
        let repetitions = PreemptiveReduction.confirmationRepetitions(discoveryIterations: discoveryInvocations)

        nonisolated(unsafe) let capturedContext = context
        let linearizableProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> __ExhaustRuntime.ContractProbeVerdict<__ExhaustRuntime.FailureEvidence<Spec>> = { commands in
            capturedContext.invocationCounter.value += 1
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
            generator: context.state.sequenceGen,
            tree: tree,
            output: taggedCommands,
            deadlineNanoseconds: context.reductionDeadlineNanoseconds,
            property: linearizableProperty
        )

        let reduced = twoPassResult.value.filter(\.0.isPrefix) + twoPassResult.value.filter { $0.0.isPrefix == false }

        if let cached = twoPassResult.lastEvidence {
            context.state.probeEvidence = cached
            return ContractReduction(finalInput: reduced, stats: twoPassResult.stats, timedOut: false)
        }

        let confirmed = __ExhaustRuntime.confirmRealFailure(
            backend: inner,
            input: reduced,
            discoveryIterations: discoveryInvocations
        )
        if let confirmed {
            context.state.probeEvidence = confirmed
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
        // Report commands prefix-first. Reduction already orders its output this way; the timeout path skips reduction, so normalize here to keep the report consistent. The partition is idempotent, so the reduced path is unaffected.
        let reduced = reduced.filter(\.0.isPrefix) + reduced.filter { $0.0.isPrefix == false }
        let replaySeed = discoveryMethod.encodeReplaySeed(seed: seed, iteration: iteration)

        let (replayResult, failureDescription) = inner.buildResult(
            reduced: reduced,
            originalCommands: originalCommands,
            seed: seed,
            replaySeed: replaySeed,
            discoveryMethod: discoveryMethod,
            timedOut: context.lastRunTimedOut
        )

        // The system under test reported to the user is always the concurrent spec that exhibited the failure, never the sequential confirmation replay.
        let systemUnderTest = context.state.probeEvidence?.outcome.concurrentSpec?.systemUnderTest
        let result = ContractResult<Spec>(
            status: replayResult.status,
            commands: replayResult.commands,
            originalCommands: replayResult.originalCommands,
            trace: replayResult.trace,
            systemUnderTest: systemUnderTest,
            seed: discoveryMethod.resultSeed(seed),
            replaySeed: replayResult.replaySeed,
            discoveryMethod: replayResult.discoveryMethod
        )

        context.state.failureContext.specName = "\(Spec.self)"
        context.state.failureContext.isPreemptive = true
        context.state.failureContext.discoveryMethod = discoveryMethod
        context.state.failureContext.replaySeed = replaySeed
        context.state.failureContext.timedOut = context.lastRunTimedOut
        context.state.failureContext.oracleDescription = failureDescription.map { "Expected state (from sequential replay):\n  \($0)" }

        if let evidence = context.state.probeEvidence {
            context.state.failureContext.failureDescription = (evidence.failureDescription ?? evidence.outcome.concurrentSpec?.failureDescription()).map { "Actual state (from concurrent execution):\n  \($0)" }
            context.state.failureContext.laneResponseValues = __ExhaustRuntime.laneResponseValues(from: evidence.outcome)
            context.state.failureContext.linearizabilityWitness = evidence.witness
        }

        let issueMessage: String = context.config.suppressIssueReporting
            ? ""
            : __ExhaustRuntime.renderPreemptiveFailure(reduced, context: context.state.failureContext)

        return (result, issueMessage)
    }
}
