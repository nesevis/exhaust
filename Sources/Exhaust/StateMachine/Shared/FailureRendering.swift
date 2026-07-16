// Formats failure reports for both the sequential and concurrent spec runners.
//
// The concurrent path (FailureContext, renderFailure(_:trace:context:), renderCommandPartition) is populated incrementally by the runner and passed to renderFailure for final formatting. The sequential path (renderFailure(_:failureInfo:failureDescription:), StateMachineFailureInfo) renders a re-executed trace from a discovered command sequence.
import CustomDump
import ExhaustCore

extension __ExhaustRuntime {
    /// Suffix appended to the lane command (in both the command partition and the execution trace) whose observed response no valid sequential ordering reproduces.
    static let linearizabilityWitnessMarker = "  ← no sequential ordering reproduces this response"

    /// Metadata accumulated during a concurrent spec run, passed to ``renderFailure(_:trace:context:)`` for final formatting.
    struct FailureContext {
        var specName: String = ""
        var discoveryMethod: StateMachineDiscoveryMethod = .randomSampling
        var seed: UInt64?
        var iteration: Int = 0
        var budget: Int = 0
        var originalCount: Int = 0
        var sequencesTested: Int = 0
        var reductionInvocations: Int = 0
        var isPreemptive: Bool = false
        var replaySeed: String?
        var oracleDescription: String?
        var failureDescription: String?
        /// Observed return values per lane (keyed by ``ScheduleMarker/rawValue``), in per-lane execution order, used to annotate each lane command with what it returned. A `nil` entry is a void command (no annotation).
        var laneResponseValues: [UInt8: [String?]]?
        /// The lane command whose observed response no valid sequential ordering reproduces, marked inline in the command partition. `nil` when the violation is only in final state (already shown by the expected-versus-actual state diff).
        var linearizabilityWitness: ResponseWitness?
    }

    /// Formats a concurrent spec failure for reporting.
    ///
    /// Renders the full failure report with command partition, execution trace, and replay seed.
    static func renderFailure(
        _ tagged: [(ScheduleMarker, some CustomStringConvertible)],
        trace: [TraceStep],
        context: FailureContext
    ) -> String {
        var lines: [String] = []
        if context.discoveryMethod == .smokeTest {
            lines.append("\(context.specName) failure (found through sequential smoke test)")
        } else if let replaySeed = context.replaySeed {
            lines.append("\(context.specName) failure (iteration \(context.iteration)/\(context.budget), found via \(context.discoveryMethod), seed \(replaySeed))")
        } else {
            lines.append("\(context.specName) failure (iteration \(context.iteration)/\(context.budget), found via \(context.discoveryMethod))")
        }
        lines.append("")

        if tagged.count < context.originalCount {
            lines.append("Reduced from \(context.originalCount) to \(tagged.count) commands.")
            lines.append("")
        }

        renderCommandPartition(
            tagged,
            into: &lines,
            laneResponseValues: context.laneResponseValues,
            linearizabilityWitness: context.linearizabilityWitness
        )

        lines.append("Execution trace:")
        for step in trace {
            lines.append("  \(step)")
        }

        if let oracleDescription = context.oracleDescription {
            lines.append("")
            lines.append(oracleDescription)
        }

        if let failureDescription = context.failureDescription {
            lines.append("")
            lines.append(failureDescription)
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

    /// Renders the command partition (prefix, lane A, lane B, ...) into the output lines.
    ///
    /// When `laneResponseValues` is supplied, each lane command is annotated with the value it returned during the concurrent execution (`getOrElse(0) → 5`), which is where a response-level linearizability violation is visible. Prefix commands are not annotated because they run deterministically. When `linearizabilityWitness` identifies a lane command, that command is marked as the one whose response no valid ordering reproduces.
    static func renderCommandPartition(
        _ tagged: [(ScheduleMarker, some CustomStringConvertible)],
        into lines: inout [String],
        laneResponseValues: [UInt8: [String?]]? = nil,
        linearizabilityWitness: ResponseWitness? = nil
    ) {
        let prefixCommands = tagged.filter(\.0.isPrefix).map(\.1)
        if prefixCommands.isEmpty == false {
            lines.append("Sequential prefix:")
            for (index, command) in prefixCommands.enumerated() {
                let entryPrefix = "  \(index + 1). "
                lines.append(indentedEntry(prefix: entryPrefix, content: String(describing: command)))
            }
            lines.append("")
        }

        let maxLane = tagged.map(\.0.rawValue).max() ?? 0
        for laneValue in UInt8(1) ... max(maxLane, 1) {
            let marker = ScheduleMarker(rawValue: laneValue)
            let laneCommands = tagged.filter { $0.0 == marker }.map(\.1)
            if laneCommands.isEmpty == false {
                let label = marker.description.uppercased()
                let values = laneResponseValues?[laneValue]
                lines.append("Lane \(label):")
                for (index, command) in laneCommands.enumerated() {
                    let annotation = if let values, index < values.count, let value = values[index] {
                        " → \(value)"
                    } else {
                        ""
                    }
                    let isWitness = linearizabilityWitness?.lane == laneValue && linearizabilityWitness?.index == index
                    let witnessMarker = isWitness ? linearizabilityWitnessMarker : ""
                    let entryPrefix = "  \(index + 1)\(label). "
                    lines.append(indentedEntry(
                        prefix: entryPrefix,
                        content: String(describing: command),
                        suffix: annotation + witnessMarker
                    ))
                }
                lines.append("")
            }
        }
    }

    private static func indentedEntry(prefix: String, content: String, suffix: String = "") -> String {
        let continuationPrefix = String(repeating: " ", count: prefix.count)
        return prefix + content.replacingOccurrences(of: "\n", with: "\n\(continuationPrefix)") + suffix
    }
}

// MARK: - Sequential Failure Rendering

extension __ExhaustRuntime {
    /// Formats a ``StateMachineResult`` and its associated failure metadata into a human-readable failure message.
    static func renderFailure<Spec: StateMachineSpecBase>(
        _ result: StateMachineResult<Spec>,
        failureInfo: StateMachineFailureInfo<Spec.Command>,
        failureDescription: String?
    ) -> String {
        var lines: [String] = []
        lines.append("State machine failure (found via \(failureInfo.discoveryMethod))")
        lines.append("")

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
    /// Captures the original command sequence and the discovery method for a spec failure, used by ``renderFailure(_:failureInfo:failureDescription:)`` to build failure reports.
    struct StateMachineFailureInfo<Command> {
        /// The original failing command sequence before reduction, if available.
        var originalCommands: [Command]?
        /// How the failure was discovered.
        var discoveryMethod: StateMachineDiscoveryMethod
    }
}
