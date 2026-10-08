import Foundation

// MARK: - Machine Pipeline

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
package extension __ExhaustRuntime {
    static func runCooperativeMachine<Spec: AsyncStateMachineSpec>(
        _: Spec.Type,
        config: ResolvedConcurrentConfig,
        regressionSeeds: [String],
        timeoutProbeCounts: UnsafeSendableBox<(attempts: Int, timedOut: Int)>,
        searchAbandonments: UnsafeSendableBox<Int>,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> (result: StateMachineResult<Spec>?, deferredIssues: [String]) {
        var deferredIssues: [String] = []
        let config = config

        let commandGen = Spec.commandGenerator.gen
        let screeningBudget = config.screeningBudget
        let resolvedCommandLimit = config.commandLimit
            ?? defaultTasksCommandLimit(
                hasEquivalence: Spec.hasEquivalence,
                commandGen: commandGen,
                screeningBudget: screeningBudget
            )

        guard let taggedCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: config.concurrencyLevel) else {
            deferredIssues.append("Command generator must be a top-level pick (.oneOf). Concurrent testing requires per-command branch structure.")
            return (nil, deferredIssues)
        }
        let sequenceGen = Gen.arrayOf(
            taggedCommandGen,
            within: 1 ... UInt64(resolvedCommandLimit),
            scaling: .constant
        )

        nonisolated(unsafe) let specInit: () -> Spec = { Spec() }
        let concurrencyLevel = config.concurrencyLevel
        let idleTimeoutMilliseconds = config.idleTimeoutMilliseconds

        let rawIdentifySkips = Spec.skipIdentifier(specInit: specInit, idleTimeoutMilliseconds: idleTimeoutMilliseconds)
        let identifySkips: @Sendable (SpecCandidateValue<Spec>) -> Set<Int> = { candidate in
            rawIdentifySkips(candidate.setupStep, candidate.taggedCommands.map(\.1))
        }

        let backend = CooperativeStateMachineBackend<Spec>(
            specInit: specInit,
            concurrencyLevel: concurrencyLevel,
            idleTimeoutMilliseconds: idleTimeoutMilliseconds,
            searchAbandonments: searchAbandonments
        )

        let invocationCounter = UnsafeSendableBox(0)
        let property: @Sendable (SpecCandidateValue<Spec>) -> Bool = { candidate in
            invocationCounter.value += 1
            timeoutProbeCounts.value.attempts += 1
            let result = CooperativeScheduler.drainAndJudge(
                taggedCommands: candidate.taggedCommands,
                setupStep: candidate.setupStep,
                specInit: specInit,
                concurrencyLevel: concurrencyLevel,
                recordTrace: false,
                idleTimeoutMilliseconds: idleTimeoutMilliseconds,
                searchAbandonments: searchAbandonments
            )
            if result.timedOut {
                // A timed-out probe is inconclusive, not a counterexample. Count it as a pass so discovery keeps sampling, and tally it for the timeout-rate warning.
                timeoutProbeCounts.value.timedOut += 1
                return true
            }
            return result.passed
        }

        var smokeSource: AnyStateMachineCandidateSource<Spec>?
        if concurrencyLevel > 1 {
            let rawSmokeProperty = asyncSequentialProperty(specInit: specInit)
            let smokeProperty: @Sendable (SpecCandidateValue<Spec>) -> Bool = { candidate in
                invocationCounter.value += 1
                return rawSmokeProperty(candidate)
            }
            // Smoke runs commands sequentially, so generate concurrency-1 (all-prefix) sequences. The candidate carries this generator and reduces sequentially even at higher lane counts.
            let smokeSequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>
            if let sequentialCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: 1) {
                smokeSequenceGen = Gen.arrayOf(sequentialCommandGen, within: 1 ... UInt64(resolvedCommandLimit), scaling: .constant)
            } else {
                smokeSequenceGen = sequenceGen
            }
            smokeSource = .smoke(sequenceGen: smokeSequenceGen, deadlineNanoseconds: config.deadlineNanoseconds, property: smokeProperty)
        }

        let pipeline = SpecPipeline(
            backend: backend,
            sequenceGen: sequenceGen,
            commandGen: commandGen,
            commandLimit: resolvedCommandLimit,
            concurrencyLevel: concurrencyLevel,
            identifySkips: identifySkips,
            property: property,
            invocationCounter: invocationCounter,
            sequenceGenForLength: { range in
                Gen.arrayOf(taggedCommandGen, within: range, scaling: .constant)
            },
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )

        let (result, issues) = pipeline.runWithRegressions(
            config: config,
            regressionSeeds: regressionSeeds,
            mainRunSmokeSource: smokeSource
        )
        deferredIssues.append(contentsOf: issues)
        return (result, deferredIssues)
    }
}

// MARK: - Command Limit

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
package extension __ExhaustRuntime {
    /// The command limit a task-based run uses when the settings name none.
    ///
    /// A spec that declares an equivalence takes the thread-based default, because every probe its equivalence rejects pays for an interleaving search whose cost grows multinomially in the sequence length. The estimate-driven limit reaches 40, which puts that search past its replay budget on a spec whose commands answer nothing — the search is then abandoned and the probe passes without judging anything, which is the outcome the lower limit exists to avoid. The startup interleaving-space warning in ``__runStateMachineConcurrent(_:settings:fileID:filePath:line:column:)`` assumes this same default.
    ///
    /// Without an equivalence a probe costs one drain and nothing searches, so the estimate stands: longer sequences reach deeper states, and the drain's cost is linear in their length.
    static func defaultTasksCommandLimit(
        hasEquivalence: Bool,
        commandGen: Generator<some Any>,
        screeningBudget: Int
    ) -> Int {
        guard hasEquivalence == false else {
            return ConcurrentSpecTunables.defaultCommandLimit
        }
        return min(estimateCommandLimit(commandGen: commandGen, screeningBudget: UInt64(screeningBudget)), 40)
    }
}
