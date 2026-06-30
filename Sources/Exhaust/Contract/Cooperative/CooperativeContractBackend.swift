import ExhaustCore

/// Runs contract probes via cooperative concurrent execution through ``drainSchedule(taggedCommands:specInit:concurrencyLevel:recordTrace:idleTimeoutMilliseconds:)``.
///
/// Async-only because `.tasks` requires ``AsyncContractSpec``. The drain loop is synchronous on the calling GCD thread, so ``probe(_:context:)`` returns without async bridging.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
struct CooperativeContractBackend<Spec: AsyncContractSpec>: ContractBackend {
    let specInit: () -> Spec
    let concurrencyLevel: Int
    let idleTimeoutMilliseconds: Int

    func probe(
        _ candidate: [(ScheduleMarker, Spec.Command)],
        context _: ContractRunContext<Spec>
    ) -> ProbeOutcome {
        let result = drainSchedule(
            taggedCommands: candidate,
            specInit: specInit,
            concurrencyLevel: concurrencyLevel,
            recordTrace: false,
            idleTimeoutMilliseconds: idleTimeoutMilliseconds
        )
        if result.timedOut {
            return .timeout
        }
        return result.passed ? .pass : .fail
    }

    func reduce(
        taggedCommands: [(ScheduleMarker, Spec.Command)],
        tree: ChoiceTree,
        context: ContractRunContext<Spec>
    ) -> ContractReduction<Spec.Command> {
        nonisolated(unsafe) let unsafeSelf = self
        nonisolated(unsafe) let unsafeContext = context
        let oracleProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> __ExhaustRuntime.ContractProbeVerdict<Void> = { commands in
            unsafeContext.invocationCounter.value += 1
            let result = unsafeSelf.probe(commands, context: unsafeContext)
            switch result {
                case .pass:
                    return .pass
                case .timeout:
                    unsafeContext.lastRunTimedOutBox?.value = true
                    return .pass
                case .fail:
                    return .fail(())
            }
        }

        let result = __ExhaustRuntime.reduceConcurrentTwoPass(
            generator: context.sequenceGen,
            tree: tree,
            output: taggedCommands,
            deadlineNanoseconds: context.reductionDeadlineNanoseconds,
            property: oracleProperty
        )
        return ContractReduction(finalInput: result.value, stats: result.stats, timedOut: false)
    }

    func buildResult(
        reduced: [(ScheduleMarker, Spec.Command)],
        originalCommands: [Spec.Command]?,
        seed: UInt64?,
        iteration: Int,
        discoveryMethod: ContractDiscoveryMethod,
        context: ContractRunContext<Spec>
    ) -> (result: ContractResult<Spec>, issueMessage: String) {
        let traceResult = drainSchedule(
            taggedCommands: reduced,
            specInit: specInit,
            concurrencyLevel: concurrencyLevel,
            recordTrace: true,
            idleTimeoutMilliseconds: idleTimeoutMilliseconds
        )

        let timedOut = context.lastRunTimedOut
        let oracle = timedOut ? nil : __ExhaustRuntime.sequentialOracle(
            commands: reduced.map(\.1),
            specInit: specInit,
            idleTimeoutMilliseconds: idleTimeoutMilliseconds
        )

        let replaySeed = discoveryMethod.encodeReplaySeed(seed: seed, iteration: iteration)

        let result = ContractResult<Spec>(
            status: timedOut ? .timeout : .fail,
            commands: reduced.map(\.1),
            originalCommands: originalCommands,
            trace: traceResult.trace,
            systemUnderTest: oracle?.systemUnderTest,
            seed: discoveryMethod.resultSeed(seed),
            replaySeed: replaySeed,
            discoveryMethod: discoveryMethod
        )

        context.failureContext.specName = "\(Spec.self)"
        context.failureContext.discoveryMethod = discoveryMethod
        context.failureContext.replaySeed = replaySeed
        context.failureContext.timedOut = timedOut
        context.failureContext.oracleDescription = oracle.flatMap { oracle in
            guard let description = oracle.failureDescription else {
                return nil
            }
            let indented = description.replacingOccurrences(of: "\n", with: "\n  ")
            return "Expected result (from sequential replay):\n  \(indented)"
        }
        context.failureContext.failureDescription = oracle?.failureDescription

        let issueMessage: String = context.config.suppressIssueReporting
            ? ""
            : __ExhaustRuntime.renderFailure(
                reduced,
                trace: traceResult.trace,
                context: context.failureContext
            )

        return (result, issueMessage)
    }
}
