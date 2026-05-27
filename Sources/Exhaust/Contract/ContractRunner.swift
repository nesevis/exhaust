// Runtime execution engine for contract property tests.
//
// Generates command sequences, executes them against a fresh spec instance, and detects postcondition / invariant violations. Integrates with the existing coverage + random + reduction pipeline.
import CustomDump
import ExhaustCore
import Foundation
import IssueReporting

// MARK: - Entry Point

public extension __ExhaustRuntime {
    /// Runs a contract property test for the given specification type.
    ///
    /// Generates command sequences using the spec's synthesized ``commandGenerator``, executes each sequence against a fresh instance, and verifies that invariants hold after every step. When a violation is found, the failing command sequence is reduced to a minimal counterexample.
    ///
    /// - Parameters:
    ///   - specType: The `@Contract`-annotated specification type.
    ///   - settings: Configuration options controlling iteration count, coverage, reduction, and command limits.
    @discardableResult
    static func __runContract<Spec: ContractSpec>(
        _ specType: Spec.Type,
        settings: [ContractSettings],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> ContractResult<Spec>? {
        let context = ContractContext(
            settings: settings,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )

        guard context.hasInvalidReplaySeed == false else {
            reportIssue(
                "Invalid replay seed",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            return nil
        }

        return ExhaustLog.withConfiguration(.init(isEnabled: context.suppressLogs == false, minimumLevel: context.logLevel, format: context.logFormat)) {
            var context = context
            let commandGen = Spec.commandGenerator
            let resolvedCommandLimit = context.commandLimit ?? estimateCommandLimit(
                commandGen: commandGen.gen,
                coverageBudget: context.coverageBudget
            )

            // Build the sequence generator: an array of commands with bounded length. Use 0 as the lower bound so the reducer can reduce sequences below the user's minimum — the minimum is a generation hint, not a reduction floor.
            let commandSequenceGenerator = commandGen.array(
                length: 0 ... resolvedCommandLimit,
                scaling: .constant
            ).gen

            // The property: execute the command sequence against a fresh spec and check for failures.
            let property: @Sendable ([Spec.Command]) -> Bool = { commands in
                var spec = Spec()
                for command in commands {
                    do {
                        try spec.run(command)
                        try spec.checkInvariants()
                    } catch is ContractSkip {
                        continue
                    } catch is ContractCheckFailure {
                        return false
                    } catch {
                        return false
                    }
                }
                return true
            }

            // If regression seeds were passed in through a Swift Testing trait, execute those first
            if let result = runRegressionSeeds(
                specType: specType,
                sequenceGenerator: commandSequenceGenerator,
                property: property,
                context: context
            ) {
                return result
            }

            guard let discovery = runCoverageAndSampling(
                specType: specType,
                commandGen: commandGen,
                commandLimit: resolvedCommandLimit,
                sequenceGenerator: commandSequenceGenerator,
                property: property,
                context: &context
            ) else {
                // The test passed
                return nil
            }

            // Re-execute the reduced sequence to build the trace and capture SUT state.
            let (trace, spec) = buildTrace(discovery.commands, specType: specType)

            let result = ContractResult<Spec>(
                commands: discovery.commands,
                trace: trace,
                systemUnderTest: spec.systemUnderTest,
                seed: context.seed,
                replaySeed: discovery.replaySeed ?? context.encodedReplaySeed,
                discoveryMethod: discovery.failureInfo.discoveryMethod
            )

            if context.suppressIssueReporting == false {
                let rendered = renderFailure(
                    result,
                    failureInfo: discovery.failureInfo,
                    modelDescription: spec.modelDescription,
                    includeDiff: context.includeDiff
                )
                ExhaustLog.error(
                    category: .propertyTest,
                    event: "contract_failed",
                    rendered
                )
                reportIssue(
                    rendered,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }

            return result
        } // withConfiguration
    }
}

// MARK: - Coverage and Sampling

private extension __ExhaustRuntime {
    struct ContractDiscovery<Command> {
        let commands: [Command]
        let failureInfo: ContractFailureInfo<Command>
        let replaySeed: String?
    }

    static func runCoverageAndSampling<Spec: ContractSpec>(
        specType _: Spec.Type,
        commandGen: ReflectiveGenerator<Spec.Command>,
        commandLimit: Int,
        sequenceGenerator: Generator<[Spec.Command]>,
        property: @escaping @Sendable ([Spec.Command]) -> Bool,
        context: inout ContractContext
    ) -> ContractDiscovery<Spec.Command>? {
        let scaOutcome = runContractCoverage(
            commandGen: commandGen.gen,
            commandLimit: commandLimit,
            sequenceGenerator: sequenceGenerator,
            property: property,
            identifySkips: Spec.skipIdentifier,
            context: context
        )

        switch scaOutcome {
            case let .failure(commands, original, coverageInvocations, reductionStats):
                if let onReport = context.onReportClosure {
                    var report = ExhaustReport()
                    report.seed = context.seed
                    report.setInvocations(
                        coverage: coverageInvocations,
                        randomSampling: 0,
                        reduction: reductionStats.map(\.totalMaterializations) ?? 0
                    )
                    if let reductionStats {
                        report.applyReductionStats(reductionStats)
                    }
                    onReport(report)
                }
                return ContractDiscovery(
                    commands: commands,
                    failureInfo: ContractFailureInfo(originalCommands: original, discoveryMethod: .coverage),
                    replaySeed: CrockfordBase32.encodeCoverageRow(coverageInvocations - 1)
                )

            case .completed, .skipped:
                guard context.coverageReplayRow == nil else {
                    return nil
                }
                return runContractSampling(
                    scaOutcome: scaOutcome,
                    sequenceGenerator: sequenceGenerator,
                    property: property,
                    context: &context
                )
        }
    }

    static func runContractCoverage<Command>(
        commandGen: Generator<Command>,
        commandLimit: Int,
        sequenceGenerator: Generator<[Command]>,
        property: @escaping @Sendable ([Command]) -> Bool,
        identifySkips: @escaping @Sendable ([Command]) -> Set<Int>,
        context: ContractContext
    ) -> SCAOutcome<Command> {
        if context.coverageReplayRow != nil {
            return runSCACoverage(
                seqGen: sequenceGenerator,
                commandGen: commandGen,
                commandLimit: commandLimit,
                coverageBudget: context.coverageBudget,
                skipToRow: context.coverageReplayRow,
                property: property,
                identifySkips: identifySkips
            )
        }
        if context.coverageBudget == 0 {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "sca_coverage_skipped",
                "SCA coverage skipped (zero coverage budget)"
            )
            return .skipped
        }
        if context.isSamplingReplay {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "sca_coverage_skipped",
                "SCA coverage skipped (deterministic replay)"
            )
            return .skipped
        }
        return runSCACoverage(
            seqGen: sequenceGenerator,
            commandGen: commandGen,
            commandLimit: commandLimit,
            coverageBudget: context.coverageBudget,
            property: property,
            identifySkips: identifySkips
        )
    }

    static func runContractSampling<Command>(
        scaOutcome: SCAOutcome<Command>,
        sequenceGenerator: Generator<[Command]>,
        property: @escaping @Sendable ([Command]) -> Bool,
        context: inout ContractContext
    ) -> ContractDiscovery<Command>? {
        let scaCoverageInvocations: Int = switch scaOutcome {
            case let .completed(count): count
            default: 0
        }

        context.ensureSeed()
        let capturedSeed = context.seed
        let samplingSettings = context.propertySettings(
            samplingBudget: context.samplingReplayIteration != nil ? 1 : context.samplingBudget,
            coverageBudget: scaOutcome.isCompleted ? UInt64(0) : context.coverageBudget,
            onReport: context.onReportClosure.map { closure in
                { report in
                    var report = report
                    report.seed = capturedSeed
                    report.coverageInvocations += scaCoverageInvocations
                    report.propertyInvocations += scaCoverageInvocations
                    closure(report)
                }
            }
        )
        let (counterexample, innerReplaySeed) = __ExhaustRuntime.withIsInterpreting(true) {
            __ExhaustRuntime.__exhaustBody(
                gen: sequenceGenerator,
                settings: samplingSettings,
                reflecting: nil,
                fileID: context.fileID,
                filePath: context.filePath,
                line: context.line,
                column: context.column,
                testName: "\(context.fileID)",
                property: property
            )
        }

        guard let counterexample else {
            return nil
        }
        return ContractDiscovery(
            commands: counterexample,
            failureInfo: ContractFailureInfo(
                originalCommands: nil,
                discoveryMethod: context.isSamplingReplay ? .replay : .randomSampling
            ),
            replaySeed: innerReplaySeed
        )
    }
}

// MARK: - Regression Seeds

private extension __ExhaustRuntime {
    static func runRegressionSeeds<Spec: ContractSpec>(
        specType: Spec.Type,
        sequenceGenerator: Generator<[Spec.Command]>,
        property: @escaping @Sendable ([Spec.Command]) -> Bool,
        context: ContractContext
    ) -> ContractResult<Spec>? {
        #if canImport(Testing)
            guard let traitConfig = ExhaustTraitConfiguration.current,
                  traitConfig.regressions.isEmpty == false
            else {
                return nil
            }

            for encodedSeed in traitConfig.regressions {
                guard let regressionSeed = CrockfordBase32.decode(encodedSeed) else {
                    reportIssue(
                        "Invalid regression seed: \(encodedSeed)",
                        fileID: context.fileID,
                        filePath: context.filePath,
                        line: context.line,
                        column: context.column
                    )
                    continue
                }
                var regressionInterpreter = ValueAndChoiceTreeInterpreter(
                    sequenceGenerator,
                    materializePicks: true,
                    seed: regressionSeed,
                    maxRuns: 1
                )
                do {
                    guard let (input, _) = try regressionInterpreter.next() else { continue }
                    if property(input) == false {
                        let (trace, spec) = buildTrace(input, specType: specType)
                        let result = ContractResult<Spec>(
                            commands: input,
                            trace: trace,
                            systemUnderTest: spec.systemUnderTest,
                            seed: regressionSeed,
                            replaySeed: CrockfordBase32.encode(regressionSeed),
                            discoveryMethod: .replay
                        )
                        if context.suppressIssueReporting == false {
                            let rendered = renderFailure(
                                result,
                                failureInfo: ContractFailureInfo(originalCommands: nil, discoveryMethod: .replay),
                                modelDescription: spec.modelDescription,
                                includeDiff: context.includeDiff
                            )
                            reportIssue(rendered, fileID: context.fileID, filePath: context.filePath, line: context.line, column: context.column)
                        }
                        return result
                    } else if context.suppressIssueReporting == false {
                        reportIssue(
                            "Regression seed \"\(encodedSeed)\" now passes — consider removing it.",
                            fileID: context.fileID,
                            filePath: context.filePath,
                            line: context.line,
                            column: context.column
                        )
                    }
                } catch {
                    reportIssue(
                        "Generator failed during regression replay (seed \(encodedSeed)): \(error)",
                        fileID: context.fileID, filePath: context.filePath, line: context.line, column: context.column
                    )
                }
            }
            return nil
        #else
            return nil
        #endif
    }
}

// MARK: - Trace Building

private extension __ExhaustRuntime {
    /// Re-executes the failing command sequence to build a step-by-step trace.
    ///
    /// Returns the trace and the spec instance in the state it was in when the failure occurred (or after running all commands if the sequence passes on re-execution).
    static func buildTrace<Spec: ContractSpec>(
        _ commands: [Spec.Command],
        specType _: Spec.Type
    ) -> ([TraceStep], Spec) {
        var spec = Spec()
        let (trace, _) = buildSequentialTrace(
            commands,
            run: { try spec.run($0) },
            checkInvariants: { try spec.checkInvariants() }
        )
        return (trace, spec)
    }
}

extension __ExhaustRuntime {
    /// Builds a sequential execution trace from a command sequence, recording per-command outcomes with invariant failure names. Shared by the sequential contract runner and the preemptive runner's smoke test.
    static func buildSequentialTrace<Command: CustomStringConvertible>(
        _ commands: [Command],
        run: (Command) throws -> Void,
        checkInvariants: () throws -> Void
    ) -> (trace: [TraceStep], failed: Bool) {
        var trace: [TraceStep] = []
        trace.reserveCapacity(commands.count)

        for (index, command) in commands.enumerated() {
            let step = index + 1
            let description = "\(command)"

            do {
                try run(command)
            } catch is ContractSkip {
                trace.append(TraceStep(index: step, command: description, outcome: .skipped))
                continue
            } catch let failure as ContractCheckFailure {
                trace.append(TraceStep(
                    index: step,
                    command: description,
                    outcome: .checkFailed(message: failure.message)
                ))
                return (trace, true)
            } catch {
                trace.append(TraceStep(
                    index: step,
                    command: description,
                    outcome: .checkFailed(message: "\(error)")
                ))
                return (trace, true)
            }

            do {
                try checkInvariants()
            } catch let failure as ContractCheckFailure {
                trace.append(TraceStep(
                    index: step,
                    command: description,
                    outcome: .invariantFailed(name: failure.message ?? "unknown")
                ))
                return (trace, true)
            } catch {
                trace.append(TraceStep(
                    index: step,
                    command: description,
                    outcome: .invariantFailed(name: "\(error)")
                ))
                return (trace, true)
            }

            trace.append(TraceStep(index: step, command: description, outcome: .ok))
        }

        return (trace, false)
    }

    /// Async variant of ``buildSequentialTrace(_:run:checkInvariants:)``.
    static func buildAsyncSequentialTrace<Command: CustomStringConvertible>(
        _ commands: [Command],
        run: (Command) async throws -> Void,
        checkInvariants: () async throws -> Void
    ) async -> (trace: [TraceStep], failed: Bool) {
        var trace: [TraceStep] = []
        trace.reserveCapacity(commands.count)

        for (index, command) in commands.enumerated() {
            let step = index + 1
            let description = "\(command)"

            do {
                try await run(command)
            } catch is ContractSkip {
                trace.append(TraceStep(index: step, command: description, outcome: .skipped))
                continue
            } catch let failure as ContractCheckFailure {
                trace.append(TraceStep(
                    index: step,
                    command: description,
                    outcome: .checkFailed(message: failure.message)
                ))
                return (trace, true)
            } catch {
                trace.append(TraceStep(
                    index: step,
                    command: description,
                    outcome: .checkFailed(message: "\(error)")
                ))
                return (trace, true)
            }

            do {
                try await checkInvariants()
            } catch let failure as ContractCheckFailure {
                trace.append(TraceStep(
                    index: step,
                    command: description,
                    outcome: .invariantFailed(name: failure.message ?? "unknown")
                ))
                return (trace, true)
            } catch {
                trace.append(TraceStep(
                    index: step,
                    command: description,
                    outcome: .invariantFailed(name: "\(error)")
                ))
                return (trace, true)
            }

            trace.append(TraceStep(index: step, command: description, outcome: .ok))
        }

        return (trace, false)
    }
}

// MARK: - Failure Rendering

extension __ExhaustRuntime {
    /// Formats a ``ContractResult`` and its associated failure metadata into a human-readable failure message.
    static func renderFailure<Spec: ContractSpecBase>(
        _ result: ContractResult<Spec>,
        failureInfo: ContractFailureInfo<Spec.Command>,
        modelDescription: String,
        includeDiff: Bool = false
    ) -> String {
        var lines: [String] = []
        lines.append("Contract failure (found via \(failureInfo.discoveryMethod))")
        lines.append("")

        // Show sequence header with reduction info when available.
        if let original = failureInfo.originalCommands, original.count > result.commands.count {
            let header =
                "Command sequence (\(result.commands.count) steps, reduced from \(original.count)):"
            lines.append(header)
        } else {
            lines.append("Command sequence (\(result.commands.count) steps):")
        }

        for step in result.trace {
            lines.append("  \(step)")
        }

        if includeDiff, let original = failureInfo.originalCommands, original.count > result.commands.count {
            let originalDescriptions = original.map { "\($0)" }
            let reducedDescriptions = result.commands.map { "\($0)" }
            if let reductionDiff = diff(originalDescriptions, reducedDescriptions) {
                lines.append("")
                lines.append("Reduction diff:")
                for line in reductionDiff.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("  \(line)")
                }
            }
        }

        lines.append("")
        lines.append("Model: \(modelDescription)")
        lines.append("SUT:   \(result.systemUnderTest)")

        if let seed = result.seed {
            lines.append("")
            let encodedSeed = result.replaySeed ?? CrockfordBase32.encode(seed)
            lines.append("Reproduce: .replay(\"\(encodedSeed)\")")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Failure Metadata

extension __ExhaustRuntime {
    /// Captures the original command sequence and the discovery method for a contract failure, used by ``renderFailure(_:failureInfo:modelDescription:)`` to build failure reports.
    struct ContractFailureInfo<Command> {
        /// The original failing command sequence before reduction, if available.
        var originalCommands: [Command]?
        /// How the failure was discovered.
        var discoveryMethod: ContractDiscoveryMethod
    }
}
