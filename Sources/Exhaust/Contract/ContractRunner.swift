// Runtime execution engine for contract property tests.
//
// Generates command sequences, executes them against a fresh spec instance, and detects postcondition / invariant violations. Integrates with the existing coverage + random + reduction pipeline.
import CustomDump
import ExhaustCore
import Foundation
import IssueReporting

/// Runs a contract property test for the given specification type.
///
/// Generates command sequences using the spec's synthesized ``commandGenerator``, executes each sequence against a fresh instance, and verifies that invariants hold after every step. When a violation is found, the failing command sequence is reduced to a minimal counterexample.
///
/// - Parameters:
///   - specType: The `@Contract`-annotated specification type.
///   - settings: Configuration options controlling iteration count, coverage, reduction, and command limits.
@discardableResult
public func __runContract<Spec: ContractSpec>(
    _ specType: Spec.Type,
    settings: [ContractSettings],
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) -> ContractResult<Spec>? {
    var commandLimit: Int?
    var budget = ExhaustBudget.standard
    var seed: UInt64?
    var suppressIssueReporting = false
    var suppressLogs = false
    var collectOpenPBTStats = false
    var includeDiff = false
    var onReportClosure: ((ExhaustReport) -> Void)?
    var logLevel: LogLevel = .error
    let logFormat: LogFormat = .keyValue
    for setting in settings {
        switch setting {
            case let .commandLimit(limit):
                commandLimit = limit
            case let .budget(b):
                budget = b
            case let .replay(replaySeed):
                seed = replaySeed.resolve()
                if seed == nil {
                    reportIssue(
                        "Invalid replay seed: \(replaySeed)",
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
                    return nil
                }
            case let .suppress(option):
                switch option {
                    case .issueReporting:
                        suppressIssueReporting = true
                    case .logs:
                        suppressLogs = true
                    case .all:
                        suppressIssueReporting = true
                        suppressLogs = true
                }
            case .collectOpenPBTStats:
                collectOpenPBTStats = true
            case .includeDiff:
                includeDiff = true
            case let .onReport(closure):
                let existing = onReportClosure
                onReportClosure = { report in
                    existing?(report)
                    closure(report)
                }
            case let .log(level):
                logLevel = level
        }
    }

    #if canImport(Testing)
        if let traitConfig = ExhaustTraitConfiguration.current {
            let hasInlineBudget = settings.contains { if case .budget = $0 { true } else { false } }
            if hasInlineBudget == false, let traitBudget = traitConfig.budget {
                budget = traitBudget
            }
        }
    #endif

    return ExhaustLog.withConfiguration(.init(isEnabled: suppressLogs == false, minimumLevel: logLevel, format: logFormat)) {
        let samplingBudget = budget.samplingBudget
        let coverageBudget = budget.coverageBudget

        let commandGen = Spec.commandGenerator
        let resolvedCommandLimit = commandLimit ?? estimateCommandLimit(
            commandGen: commandGen.gen,
            coverageBudget: coverageBudget
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

        #if canImport(Testing)
            if let traitConfig = ExhaustTraitConfiguration.current, traitConfig.regressions.isEmpty == false {
                for encodedSeed in traitConfig.regressions {
                    guard let regressionSeed = CrockfordBase32.decode(encodedSeed) else {
                        reportIssue(
                            "Invalid regression seed: \(encodedSeed)",
                            fileID: fileID,
                            filePath: filePath,
                            line: line,
                            column: column
                        )
                        continue
                    }
                    var regressionInterpreter = ValueAndChoiceTreeInterpreter(
                        commandSequenceGenerator,
                        materializePicks: true,
                        seed: regressionSeed,
                        maxRuns: 1
                    )
                    do {
                        if let (input, _) = try regressionInterpreter.next() {
                            if property(input) == false {
                                let (trace, spec) = buildTrace(input, specType: specType)
                                let result = ContractResult<Spec>(
                                    commands: input,
                                    trace: trace,
                                    systemUnderTest: spec.systemUnderTest,
                                    seed: regressionSeed,
                                    discoveryMethod: .replay
                                )
                                if suppressIssueReporting == false {
                                    let rendered = renderFailure(
                                        result,
                                        failureInfo: ContractFailureInfo(originalCommands: nil, discoveryMethod: .replay),
                                        modelDescription: spec.modelDescription,
                                        includeDiff: includeDiff
                                    )
                                    reportIssue(rendered, fileID: fileID, filePath: filePath, line: line, column: column)
                                }
                                return result
                            } else if suppressIssueReporting == false {
                                reportIssue(
                                    "Regression seed \"\(encodedSeed)\" now passes — consider removing it.",
                                    fileID: fileID,
                                    filePath: filePath,
                                    line: line,
                                    column: column
                                )
                            }
                        }
                    } catch {
                        reportIssue(
                            "Generator failed during regression replay (seed \(encodedSeed)): \(error)",
                            fileID: fileID, filePath: filePath, line: line, column: column
                        )
                    }
                }
            }
        #endif

        var scaOutcome: SCAOutcome<Spec.Command> = .skipped
        if coverageBudget == 0 {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "sca_coverage_skipped",
                "SCA coverage skipped (zero coverage budget)"
            )
        } else if seed != nil {
            ExhaustLog.notice(
                category: .propertyTest,
                event: "sca_coverage_skipped",
                "SCA coverage skipped (deterministic replay)"
            )
        } else {
            scaOutcome = runSCACoverage(
                seqGen: commandSequenceGenerator,
                commandGen: commandGen.gen,
                commandLimit: resolvedCommandLimit,
                coverageBudget: coverageBudget,
                property: property,
                identifySkips: Spec.skipIdentifier
            )
        }

        let failingSequence: [Spec.Command]?
        let failureInfo: ContractFailureInfo<Spec.Command>
        switch scaOutcome {
            case let .failure(commands, original, coverageInvocations, reductionStats):
                failingSequence = commands
                failureInfo = ContractFailureInfo(
                    originalCommands: original,
                    discoveryMethod: .coverage
                )
                if let onReportClosure {
                    var report = ExhaustReport()
                    report.seed = seed
                    report.setInvocations(
                        coverage: coverageInvocations,
                        randomSampling: 0,
                        reduction: reductionStats.map(\.totalMaterializations) ?? 0
                    )
                    if let reductionStats {
                        report.applyReductionStats(reductionStats)
                    }
                    onReportClosure(report)
                }
            case .completed, .skipped:
                let scaCoverageInvocations: Int
                if case let .completed(count) = scaOutcome {
                    scaCoverageInvocations = count
                } else {
                    scaCoverageInvocations = 0
                }
                var innerReport: ExhaustReport?
                let onInnerReport: ((ExhaustReport) -> Void)? = onReportClosure.map { _ in
                    { report in innerReport = report }
                }
                failingSequence = __ExhaustRuntime.__exhaust(
                    commandSequenceGenerator.wrapped,
                    settings: buildPropertySettings(
                        samplingBudget: samplingBudget,
                        coverageBudget: scaOutcome.isCompleted ? UInt64(0) : coverageBudget,
                        seed: seed,
                        suppressIssueReporting: true,
                        collectOpenPBTStats: collectOpenPBTStats,
                        onReport: onInnerReport,
                        logLevel: logLevel
                    ),
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column,
                    property: property
                )
                if let onReportClosure {
                    var report = innerReport ?? ExhaustReport()
                    report.seed = seed
                    report.coverageInvocations += scaCoverageInvocations
                    report.propertyInvocations += scaCoverageInvocations
                    onReportClosure(report)
                }
                failureInfo = ContractFailureInfo(
                    originalCommands: nil,
                    discoveryMethod: seed != nil ? .replay : .randomSampling
                )
        }

        guard let failingSequence else {
            return nil
        }

        // Re-execute the reduced sequence to build the trace and capture SUT state.
        let (trace, spec) = buildTrace(failingSequence, specType: specType)

        let result = ContractResult<Spec>(
            commands: failingSequence,
            trace: trace,
            systemUnderTest: spec.systemUnderTest,
            seed: seed,
            discoveryMethod: failureInfo.discoveryMethod
        )

        if suppressIssueReporting == false {
            let rendered = renderFailure(
                result,
                failureInfo: failureInfo,
                modelDescription: spec.modelDescription,
                includeDiff: includeDiff
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

// MARK: - Trace building

/// Re-executes the failing command sequence to build a step-by-step trace.
///
/// Returns the trace and the spec instance in the state it was in when the failure occurred (or after running all commands if the sequence passes on re-execution).
private func buildTrace<Spec: ContractSpec>(
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

/// Builds a sequential execution trace from a command sequence, recording per-command outcomes with invariant failure names. Shared by the sequential contract runner and the preemptive runner's smoke test.
func buildSequentialTrace<Command: CustomStringConvertible>(
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
func buildAsyncSequentialTrace<Command: CustomStringConvertible>(
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

// MARK: - Failure rendering

/// Formats a ``ContractResult`` and its associated failure metadata into a human-readable failure message.
func renderFailure<Spec: ContractSpecBase>(
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
        lines.append("Reproduce: .replay(\"\(CrockfordBase32.encode(seed))\")")
    }

    return lines.joined(separator: "\n")
}

// MARK: - Failure metadata

/// Captures the original command sequence and the discovery method for a contract failure, used by ``renderFailure(_:failureInfo:modelDescription:)`` to build failure reports.
struct ContractFailureInfo<Command> {
    /// The original failing command sequence before reduction, if available.
    var originalCommands: [Command]?
    /// How the failure was discovered.
    var discoveryMethod: ContractDiscoveryMethod
}

/// Builds a ``PropertySettings`` array from contract runner parameters, wiring budget, seed, logging, and diagnostic options.
func buildPropertySettings(
    samplingBudget: UInt64,
    coverageBudget: UInt64,
    seed: UInt64?,
    suppressIssueReporting: Bool,
    collectOpenPBTStats: Bool = false,
    onReport: ((ExhaustReport) -> Void)? = nil,
    logLevel: LogLevel = .error
) -> [PropertySettings] {
    var settings: [PropertySettings] = [
        .budget(.custom(
            coverage: coverageBudget,
            sampling: samplingBudget
        )),
    ]
    if let seed {
        settings.append(.replay(.numeric(seed)))
    }
    if suppressIssueReporting {
        settings.append(.suppress(.issueReporting))
    }
    if collectOpenPBTStats {
        settings.append(.collectOpenPBTStats)
    }
    if let onReport {
        settings.append(.onReport(onReport))
    }
    settings.append(.log(logLevel))
    return settings
}
