// Formats failure reports for both the sequential and concurrent contract runners.
//
// The concurrent path (FailureContext, renderFailure(_:trace:context:), renderTimeout, renderCommandPartition) is populated incrementally by the runner and passed to renderFailure for final formatting. The sequential path (renderFailure(_:failureInfo:failureDescription:includeDiff:), ContractFailureInfo) renders a re-executed trace from a discovered command sequence.
import CustomDump
import ExhaustCore

extension __ExhaustRuntime {
    /// Metadata accumulated during a concurrent contract run, passed to ``renderFailure(_:trace:context:)`` for final formatting.
    struct FailureContext {
        var specName: String = ""
        var discoveryMethod: ContractDiscoveryMethod = .randomSampling
        var seed: UInt64?
        var iteration: Int = 0
        var budget: UInt64 = 0
        var originalCount: Int = 0
        var sequencesTested: Int = 0
        var reductionInvocations: Int = 0
        var timedOut: Bool = false
        var isPreemptive: Bool = false
        var replaySeed: String?
        var oracleDescription: String?
    }

    /// Formats a concurrent contract failure for reporting.
    ///
    /// Delegates to ``renderTimeout(_:trace:)`` when `context.timedOut` is true. Otherwise renders the full failure report with command partition, execution trace, and replay seed.
    static func renderFailure(
        _ tagged: [(ScheduleMarker, some CustomStringConvertible)],
        trace: [TraceStep],
        context: FailureContext
    ) -> String {
        if context.timedOut {
            return renderTimeout(tagged, trace: trace)
        }

        var lines: [String] = []
        if let replaySeed = context.replaySeed {
            lines.append("\(context.specName) failure (iteration \(context.iteration)/\(context.budget), found via \(context.discoveryMethod), seed \(replaySeed))")
        } else {
            lines.append("\(context.specName) failure (iteration \(context.iteration)/\(context.budget), found via \(context.discoveryMethod))")
        }
        lines.append("")

        if tagged.count < context.originalCount {
            lines.append("Reduced from \(context.originalCount) to \(tagged.count) commands.")
            lines.append("")
        }

        renderCommandPartition(tagged, into: &lines)

        lines.append("Execution trace:")
        for step in trace {
            lines.append("  \(step)")
        }

        if let oracleDescription = context.oracleDescription {
            lines.append("")
            lines.append(oracleDescription)
        }

        if tagged.isEmpty == false, tagged.allSatisfy(\.0.isPrefix) {
            lines.append("")
            lines.append("Note: all commands were reduced to the sequential prefix. This failure reproduces without concurrency and is likely a sequential bug, not a race condition.")
        }

        lines.append("")
        lines.append("Command sequences tested: \(context.sequencesTested + context.reductionInvocations)")

        if let replaySeed = context.replaySeed {
            lines.append("")
            lines.append("Reproduce: .replay(\"\(replaySeed)\")")
        }

        if context.isPreemptive {
            lines.append("")
            lines.append("* Preemptive scheduling depends on OS thread timing and may not reproduce on every run. Run the test repeatedly to reproduce.")
        }

        return lines.joined(separator: "\n")
    }

    /// Formats a timeout diagnostic when the drain loop stalls with no pending continuations.
    static func renderTimeout(
        _ tagged: [(ScheduleMarker, some CustomStringConvertible)],
        trace: [TraceStep]
    ) -> String {
        var lines: [String] = []
        lines.append("Concurrent contract timed out: the drain loop stalled with no pending continuations.")
        lines.append("This typically means a command body suspended to a foreign executor (custom-executor actor, Task.sleep, or blocking I/O) that does not flow through the cooperative scheduler.")
        lines.append("")

        renderCommandPartition(tagged, into: &lines)

        if trace.isEmpty == false {
            lines.append("Partial execution trace (up to stall point):")
            for step in trace {
                lines.append("  \(step)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Renders the command partition (prefix, lane A, lane B, ...) into the output lines.
    static func renderCommandPartition(
        _ tagged: [(ScheduleMarker, some CustomStringConvertible)],
        into lines: inout [String]
    ) {
        let prefixCommands = tagged.filter(\.0.isPrefix).map(\.1)
        if prefixCommands.isEmpty == false {
            lines.append("Sequential prefix:")
            for (index, command) in prefixCommands.enumerated() {
                lines.append("  \(index + 1). \(command)")
            }
            lines.append("")
        }

        let maxLane = tagged.map(\.0.rawValue).max() ?? 0
        for laneValue in UInt8(1) ... max(maxLane, 1) {
            let marker = ScheduleMarker(rawValue: laneValue)
            let laneCommands = tagged.filter { $0.0 == marker }.map(\.1)
            if laneCommands.isEmpty == false {
                let label = marker.description.uppercased()
                lines.append("Lane \(label):")
                for (index, command) in laneCommands.enumerated() {
                    lines.append("  \(index + 1)\(label). \(command)")
                }
                lines.append("")
            }
        }
    }
}

// MARK: - Sequential Failure Rendering

extension __ExhaustRuntime {
    /// Formats a ``ContractResult`` and its associated failure metadata into a human-readable failure message.
    static func renderFailure<Spec: ContractSpecBase>(
        _ result: ContractResult<Spec>,
        failureInfo: ContractFailureInfo<Spec.Command>,
        failureDescription: String?,
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

        if let failureDescription {
            let indentedDescription = failureDescription.replacingOccurrences(of: "\n", with: "\n  ")
            lines.append("")
            lines.append("State: \(indentedDescription)")
        }

        if let encodedSeed = result.replaySeed ?? result.seed.map(ReplaySeed.encodeRawSeed) {
            lines.append("")
            lines.append("Reproduce: .replay(\"\(encodedSeed)\")")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Sequential Failure Metadata

extension __ExhaustRuntime {
    /// Captures the original command sequence and the discovery method for a contract failure, used by ``renderFailure(_:failureInfo:failureDescription:)`` to build failure reports.
    struct ContractFailureInfo<Command> {
        /// The original failing command sequence before reduction, if available.
        var originalCommands: [Command]?
        /// How the failure was discovered.
        var discoveryMethod: ContractDiscoveryMethod
    }
}
