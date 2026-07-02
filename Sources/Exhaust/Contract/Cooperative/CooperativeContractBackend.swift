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
        nonisolated(unsafe) let capturedContext = context
        // A probe that times out during reduction is not a counterexample. Abort further reduction and keep the original failure as-is rather than reducing toward a hang.
        nonisolated(unsafe) var reductionTimedOut = false
        let oracleProperty: @Sendable ([(ScheduleMarker, Spec.Command)]) -> __ExhaustRuntime.ContractProbeVerdict<Void> = { commands in
            guard reductionTimedOut == false else {
                return .pass
            }
            capturedContext.invocationCounter.value += 1
            let result = unsafeSelf.probe(commands, context: capturedContext)
            switch result {
                case .pass:
                    return .pass
                case .timeout:
                    ExhaustLog.notice(category: .reducer, event: "cooperative_reduction_timeout")
                    reductionTimedOut = true
                    return .pass
                case .fail:
                    return .fail(())
            }
        }

        let result = __ExhaustRuntime.reduceConcurrentTwoPass(
            generator: context.state.sequenceGen,
            tree: tree,
            output: taggedCommands,
            deadlineNanoseconds: context.reductionDeadlineNanoseconds,
            property: oracleProperty
        )
        return ContractReduction(finalInput: result.value, stats: result.stats, timedOut: reductionTimedOut)
    }

    func buildResult(
        reduced: [(ScheduleMarker, Spec.Command)],
        originalCommands: [Spec.Command]?,
        seed: UInt64?,
        iteration: Int,
        discoveryMethod: ContractDiscoveryMethod,
        context: ContractRunContext<Spec>
    ) -> (result: ContractResult<Spec>, issueMessage: String) {
        let reduced = reduced.prefixFirstOrder()

        let traceResult = drainSchedule(
            taggedCommands: reduced,
            specInit: specInit,
            concurrencyLevel: concurrencyLevel,
            recordTrace: true,
            idleTimeoutMilliseconds: idleTimeoutMilliseconds
        )

        let oracle = __ExhaustRuntime.sequentialOracle(
            commands: reduced.map(\.1),
            specInit: specInit,
            idleTimeoutMilliseconds: idleTimeoutMilliseconds
        )

        let replaySeed = discoveryMethod.encodeReplaySeed(seed: seed, iteration: iteration)

        let result = ContractResult<Spec>(
            status: .fail,
            commands: reduced.map(\.1),
            originalCommands: originalCommands,
            trace: traceResult.trace,
            systemUnderTest: traceResult.systemUnderTest,
            seed: discoveryMethod.resultSeed(seed),
            replaySeed: replaySeed,
            discoveryMethod: discoveryMethod
        )

        context.state.failureContext.specName = "\(Spec.self)"
        context.state.failureContext.discoveryMethod = discoveryMethod
        context.state.failureContext.replaySeed = replaySeed
        context.state.failureContext.oracleDescription = oracle.flatMap { oracle in
            guard let description = oracle.failureDescription else {
                return nil
            }
            let indented = description.replacingOccurrences(of: "\n", with: "\n  ")
            return "Expected result (from sequential replay):\n  \(indented)"
        }
        context.state.failureContext.failureDescription = traceResult.failureDescription.map {
            let indented = $0.replacingOccurrences(of: "\n", with: "\n  ")
            return "Actual state (from concurrent execution):\n  \(indented)"
        }

        let issueMessage: String = context.config.suppressIssueReporting
            ? ""
            : __ExhaustRuntime.renderFailure(
                reduced,
                trace: traceResult.trace,
                context: context.state.failureContext
            )

        return (result, issueMessage)
    }
}
