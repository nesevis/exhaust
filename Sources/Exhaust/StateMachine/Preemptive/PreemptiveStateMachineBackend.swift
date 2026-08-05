import ExhaustCore

/// Runs spec probes via preemptive concurrent execution on real GCD threads.
///
/// Generic over ``PreemptiveBackend``, which has synchronous (``PreemptiveChecker``) and async (``AsyncPreemptiveChecker``) conformers. The backend adapts the existing per-probe execution and linearizability checking into the ``StateMachineBackend`` protocol so the ``SpecMachine`` can drive the preemptive pipeline identically to the cooperative and sequential paths.
struct PreemptiveStateMachineBackend<Inner: PreemptiveBackend>: StateMachineBackend {
    typealias Spec = Inner.Spec

    let inner: Inner
    let concurrencyLevel: Int

    // MARK: - Probe

    func probe(
        _ candidate: SpecCandidateValue<Spec>,
        context _: StateMachineRunContext<Spec>
    ) -> ProbeOutcome {
        let partition = LanePartition(markers: candidate.taggedCommands.map(\.0))
        let outcome = inner.execute(candidate.taggedCommands, setupStep: candidate.setupStep, partition: partition)
        if case .timedOut = outcome {
            return .timeout
        }
        // Evidence is established only by reduction and final confirmation, which run against the reduced sequence. Pruning probes run against pre-reduction sequences, so they must not leak their evidence into the final report.
        let isFailure = __ExhaustRuntime.classifyFailure(
            taggedCommands: candidate.taggedCommands,
            setupStep: candidate.setupStep,
            outcome: outcome,
            backend: inner
        ) != nil
        return isFailure ? .fail : .pass
    }

    // MARK: - Reduce

    func reduce(
        setupStep: Spec.SetupStep?,
        taggedCommands: [(ScheduleMarker, Spec.Command)],
        tree: ChoiceTree,
        context: StateMachineRunContext<Spec>
    ) -> StateMachineReduction<Spec.Command> {
        let discoveryInvocations = context.invocationCounter.value
        let repetitions = PreemptiveConfirmation.confirmationRepetitions(discoveryIterations: discoveryInvocations)

        nonisolated(unsafe) let capturedContext = context
        let linearizableProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> __ExhaustRuntime.StateMachineProbeVerdict<__ExhaustRuntime.FailureEvidence<Spec>> = { commands in
            // One increment per candidate, covering all confirmation repetitions. This site cannot go through countedProbe because it calls inner.execute directly to carry evidence and repetitions.
            capturedContext.invocationCounter.value += 1
            let partition = LanePartition(markers: commands.map(\.0))
            for _ in 0 ..< repetitions {
                let outcome = inner.execute(commands, setupStep: setupStep, partition: partition)
                if case .timedOut = outcome {
                    // A probe that times out during reduction is not a counterexample. Abort further reduction and keep the failure as-is rather than reducing toward a hang.
                    ExhaustLog.notice(category: .reducer, event: "preemptive_reduction_timeout")
                    return .abort
                }
                if let evidence = __ExhaustRuntime.classifyFailure(
                    taggedCommands: commands,
                    setupStep: setupStep,
                    outcome: outcome,
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

        let reduced = twoPassResult.value.prefixFirstOrder()

        let confirmed = __ExhaustRuntime.confirmRealFailure(
            backend: inner,
            input: reduced,
            setupStep: setupStep,
            discoveryIterations: discoveryInvocations
        )
        if let confirmed {
            context.state.probeEvidence = confirmed
        } else if let cached = twoPassResult.lastEvidence {
            context.state.probeEvidence = cached
        }
        return StateMachineReduction(finalInput: reduced, stats: twoPassResult.stats, timedOut: twoPassResult.aborted)
    }

    // MARK: - Build Result

    func buildResult(
        setupStep: Spec.SetupStep?,
        reduced: [(ScheduleMarker, Spec.Command)],
        originalCommands: [Spec.Command]?,
        provenance: StateMachineCandidateProvenance,
        iteration: Int,
        context: StateMachineRunContext<Spec>
    ) -> (result: StateMachineResult<Spec>, issueMessage: String) {
        // Reduction already orders its output prefix-first, but the timeout path skips reduction entirely, so normalize here as well. The partition is idempotent, so the reduced path is unaffected.
        let reduced = reduced.prefixFirstOrder()
        let discoveryMethod = provenance.discoveryMethod
        let replaySeed = provenance.encodeReplaySeed(iteration: iteration)
        // Replayed on a fresh spec so the trace carries the setup's real outcome: a setup throw renders as the failing step instead of a fabricated success.
        let setupSteps = inner.setupTraceSteps(setupStep)

        let failureDescription = inner.sequentialReplayDescription(of: reduced, setupStep: setupStep)

        // The system under test reported to the user is always the concurrent spec that exhibited the failure, never the sequential confirmation replay.
        let result = StateMachineResult<Spec>(
            commands: reduced.map(\.1),
            originalCommands: originalCommands,
            setup: setupStep,
            trace: __ExhaustRuntime.buildPreemptiveTrace(reduced, setupSteps: setupSteps),
            systemUnderTest: context.state.probeEvidence?.outcome.concurrentSpec?.systemUnderTest,
            seed: provenance.resultSeed,
            replaySeed: replaySeed,
            discoveryMethod: discoveryMethod
        )

        context.state.failureContext.specName = "\(Spec.self)"
        context.state.failureContext.mode = .threads
        context.state.failureContext.discoveryMethod = discoveryMethod
        context.state.failureContext.replaySeed = replaySeed
        context.state.failureContext.oracleDescription = failureDescription.map { "Expected state (from sequential replay):\n  \($0)" }

        if let evidence = context.state.probeEvidence {
            context.state.failureContext.failureDescription = (evidence.failureDescription ?? evidence.outcome.concurrentSpec?.failureDescription()).map { "Actual state (from concurrent execution):\n  \($0)" }
            context.state.failureContext.laneResponseValues = __ExhaustRuntime.laneResponseValues(from: evidence.outcome)
            context.state.failureContext.linearizabilityWitness = evidence.witness
        }

        let issueMessage: String = context.config.suppress.issueReporting
            ? ""
            : __ExhaustRuntime.renderPreemptiveFailure(reduced, setupSteps: setupSteps, context: context.state.failureContext)

        return (result, issueMessage)
    }
}
