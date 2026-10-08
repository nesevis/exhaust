import Foundation

package extension __ExhaustRuntime {
    static func runAsyncSequentialPipeline<Spec: AsyncStateMachineSpec>(
        _: Spec.Type,
        config: ResolvedConcurrentConfig,
        regressionSeeds: [String] = [],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> (result: StateMachineResult<Spec>?, deferredIssues: [String]) {
        var deferredIssues: [String] = []

        let commandGen = Spec.commandGenerator
        let commandLimit = config.commandLimit ?? estimateCommandLimit(
            commandGen: commandGen.gen,
            screeningBudget: UInt64(config.screeningBudget)
        )
        let taggedSeqGen = taggedSequenceGenerator(commandGen: commandGen, commandLimit: commandLimit)

        nonisolated(unsafe) let specInit: () -> Spec = { Spec() }

        let invocationCounter = UnsafeSendableBox(0)
        let rawProperty: @Sendable (SpecCandidateValue<Spec>) -> Bool = asyncSequentialProperty(specInit: specInit)
        let property: @Sendable (SpecCandidateValue<Spec>) -> Bool = { candidate in
            invocationCounter.value += 1
            return rawProperty(candidate)
        }

        let asyncSkipIdentifier = Spec.skipIdentifier(specInit: specInit)
        let identifySkips: @Sendable (SpecCandidateValue<Spec>) -> Set<Int> = { candidate in
            asyncSkipIdentifier(candidate.setupStep, candidate.taggedCommands.map(\.1))
        }

        let backend = SequentialStateMachineBackend<Spec>(
            property: property,
            finalize: { candidate in
                let commands = candidate.taggedCommands.map(\.1)
                let setupStep = candidate.setupStep
                return __ExhaustRuntime._blockingAwaitSemaphore {
                    let spec = specInit()
                    let (setupTrace, setupFailed) = await applySetupRecordingTrace(spec, setupStep: setupStep)
                    guard setupFailed == false else {
                        return (setupTrace, spec.systemUnderTest, spec.failureDescription())
                    }
                    let (trace, _) = await buildAsyncSequentialTrace(
                        commands,
                        run: { try await spec.run($0) },
                        checkInvariants: { try await spec.checkInvariants() }
                    )
                    return (joinTrace(setup: setupTrace, commands: trace), spec.systemUnderTest, spec.failureDescription())
                }!
            }
        )

        let pipeline = SpecPipeline(
            backend: backend,
            sequenceGen: taggedSeqGen,
            commandGen: commandGen.gen,
            commandLimit: commandLimit,
            concurrencyLevel: nil,
            identifySkips: identifySkips,
            property: property,
            invocationCounter: invocationCounter,
            sequenceGenForLength: nil,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )

        let (result, issues) = pipeline.runWithRegressions(
            config: config,
            regressionSeeds: regressionSeeds
        )
        deferredIssues.append(contentsOf: issues)
        return (result, deferredIssues)
    }
}

// MARK: - Regression Seed Replay

package extension __ExhaustRuntime {
    /// Replays each regression seed through a caller-supplied machine runner, returning the first failure.
    ///
    /// Shared by the cooperative and preemptive entry points. Decodes each seed, builds a modified config (expanding the screening budget for `.screening(row)` seeds), and delegates to `runMachine`. Returns `nil` result when all seeds pass.
    static func replayRegressionSeeds<Spec: StateMachineSpecBase>(
        config: ResolvedConcurrentConfig,
        regressionSeeds: [String],
        runMachine: (ResolvedConcurrentConfig) -> (result: StateMachineResult<Spec>?, issues: [String])
    ) -> (result: StateMachineResult<Spec>?, deferredIssues: [String]) {
        var deferredIssues: [String] = []

        guard config.screeningReplay == nil, config.seed == nil else {
            return (nil, deferredIssues)
        }

        for encodedSeed in regressionSeeds {
            guard config.hasExceededDeadline == false else {
                break
            }
            guard let decoded = ReplaySeed.Resolved.decode(encodedSeed) else {
                deferredIssues.append("Invalid regression seed: \(encodedSeed)")
                continue
            }

            var replayConfig = config
            switch decoded {
                case let .specScreening(resolvedSeed, row, tierLength):
                    replayConfig.screeningReplay = (tierLength: tierLength, row: row)
                    replayConfig.coveringSeed = resolvedSeed
                case .valueScreening:
                    deferredIssues.append("Screening regression seed lacks a tier marker: \(encodedSeed)")
                    continue
                case let .sampling(seed, iteration?):
                    replayConfig.seed = seed
                    replayConfig.replayIteration = iteration
                    replayConfig.coveringSeed = seed
                    if replayConfig.samplingBudget < iteration + 1 {
                        replayConfig.samplingBudget = iteration + 1
                    }
                case let .sampling(seed, nil):
                    replayConfig.seed = seed
                    replayConfig.coveringSeed = seed
            }

            let (result, issues) = runMachine(replayConfig)
            deferredIssues.append(contentsOf: issues)
            if let result {
                return (result, deferredIssues)
            }
            // Seed replays clean — the bug it guards against stayed fixed. The seed
            // sits inert as a silent regression guard until the property fails again.
        }

        return (nil, deferredIssues)
    }
}

// MARK: - Trace Building

package extension __ExhaustRuntime {
    static func buildTrace<Spec: StateMachineSpec>(
        _ candidate: SpecCandidateValue<Spec>,
        specType _: Spec.Type
    ) -> ([TraceStep], Spec) {
        let (spec, setupTrace, setupFailed) = makeSpecRecordingSetupTrace(Spec.self, setupStep: candidate.setupStep)
        if setupFailed {
            return (setupTrace, spec)
        }
        let (trace, _) = buildSequentialTrace(
            candidate.taggedCommands.map(\.1),
            run: { try spec.run($0) },
            checkInvariants: { try spec.checkInvariants() }
        )
        return (joinTrace(setup: setupTrace, commands: trace), spec)
    }
}
