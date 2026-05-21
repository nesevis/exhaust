// Formats failure reports, timeout diagnostics, and command partitions for the concurrent contract runner. FailureContext is populated incrementally by the runner and passed to renderFailure for final formatting.
import ExhaustCore

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
    var oracleDescription: String?
}

/// Formats a concurrent contract failure for reporting.
///
/// Delegates to ``renderTimeout(_:trace:)`` when `context.timedOut` is true. Otherwise renders the full failure report with command partition, execution trace, and replay seed.
func renderFailure(
    _ tagged: [(ScheduleMarker, some CustomStringConvertible)],
    trace: [TraceStep],
    context: FailureContext
) -> String {
    if context.timedOut {
        return renderTimeout(tagged, trace: trace)
    }

    var lines: [String] = []
    if let seed = context.seed {
        lines.append("\(context.specName) failure (iteration \(context.iteration)/\(context.budget), found via \(context.discoveryMethod), seed \(CrockfordBase32.encode(seed)))")
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

    lines.append("")
    lines.append("Command sequences tested: \(context.sequencesTested + context.reductionInvocations)")

    if let seed = context.seed {
        lines.append("")
        lines.append("Reproduce: .replay(\"\(CrockfordBase32.encode(seed))\")")
    }

    return lines.joined(separator: "\n")
}

/// Formats a timeout diagnostic when the drain loop stalls with no pending continuations.
func renderTimeout(
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
func renderCommandPartition(
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
