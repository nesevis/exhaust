// Converts structured trace events from the cooperative drain loop into presentable TraceSteps. Two post-processing passes: collapse no-op suspend/resume pairs, and merge adjacent started+completed pairs.

/// A raw event emitted by the cooperative drain loop during command execution. These are intermediate records that ``buildTrace(_:)`` post-processes into presentable ``TraceStep`` values — collapsing no-op suspend/resume pairs and merging adjacent started+completed events for the same command.
struct TraceEvent: Sendable {
    enum Kind: Sendable {
        case started
        case completed
        case failed(message: String)
        case suspended
        case resumed
    }

    var kind: Kind
    var lane: String
    var label: String
}

/// Converts structured trace events into presentable TraceSteps with phase annotations.
///
/// Performs two post-processing passes: (1) removes suspended/resumed pairs where no interleaving actually occurred between them, and (2) collapses adjacent started+completed pairs into a single entry.
func buildTrace(_ events: [TraceEvent]) -> [TraceStep] {
    var steps: [(step: TraceStep, lane: String)] = []
    var openCommand: [String: String] = [:]
    var stepNumber = 0

    for event in events {
        switch event.kind {
        case .started:
            if event.lane != "prefix" {
                openCommand[event.lane] = event.label
            }
            stepNumber += 1
            let phase = event.lane == "prefix" ? "(prefix)" : "(started)"
            steps.append((TraceStep(index: stepNumber, command: "\(event.label) \(phase)", outcome: .ok), event.lane))
        case .completed:
            openCommand[event.lane] = nil
            if event.lane == "prefix" {
                if let lastIndex = steps.lastIndex(where: { $0.step.command == "\(event.label) (prefix)" }) {
                    steps.remove(at: lastIndex)
                    stepNumber -= 1
                }
                stepNumber += 1
                steps.append((TraceStep(index: stepNumber, command: "\(event.label) (prefix)", outcome: .ok), event.lane))
            } else {
                stepNumber += 1
                steps.append((TraceStep(index: stepNumber, command: "\(event.label) (completed)", outcome: .ok), event.lane))
            }
        case let .failed(message):
            openCommand[event.lane] = nil
            stepNumber += 1
            let phase = event.lane == "prefix" ? "(prefix)" : "(completed)"
            steps.append((TraceStep(index: stepNumber, command: "\(event.label) \(phase)", outcome: .invariantFailed(name: message)), event.lane))
        case .suspended:
            if let current = openCommand[event.lane] {
                stepNumber += 1
                steps.append((TraceStep(index: stepNumber, command: "\(current) (suspended)", outcome: .ok), event.lane))
            }
        case .resumed:
            if let current = openCommand[event.lane] {
                stepNumber += 1
                steps.append((TraceStep(index: stepNumber, command: "\(current) (resumed)", outcome: .ok), event.lane))
            }
        }
    }

    // Remove suspended/resumed pairs where no other lane ran between them.
    var filtered: [(step: TraceStep, lane: String)] = []
    var index = 0
    while index < steps.count {
        let entry = steps[index]
        if entry.step.command.hasSuffix("(suspended)") {
            let commandBase = entry.step.command.replacingOccurrences(of: " (suspended)", with: "")
            var hasInterleaving = false
            var resumeIndex: Int?
            for ahead in (index + 1) ..< steps.count {
                let aheadCmd = steps[ahead].step.command
                if aheadCmd.hasPrefix(commandBase) &&
                    (aheadCmd.hasSuffix("(resumed)") || aheadCmd.hasSuffix("(completed)"))
                {
                    resumeIndex = ahead
                    break
                }
                if steps[ahead].lane != entry.lane {
                    hasInterleaving = true
                }
            }

            if hasInterleaving {
                filtered.append(entry)
            } else if let ri = resumeIndex, steps[ri].step.command.hasSuffix("(resumed)") {
                index = ri + 1
                continue
            } else {
                filtered.append(entry)
            }
        } else {
            filtered.append(entry)
        }
        index += 1
    }

    // Collapse: started immediately followed by completed for the same command
    var collapsed: [TraceStep] = []
    index = 0
    while index < filtered.count {
        if index + 1 < filtered.count,
           filtered[index].step.command.hasSuffix("(started)"),
           filtered[index + 1].step.command.hasSuffix("(completed)")
        {
            let startCmd = filtered[index].step.command.replacingOccurrences(of: " (started)", with: "")
            let nextCmd = filtered[index + 1].step.command.replacingOccurrences(of: " (completed)", with: "")
            if startCmd == nextCmd {
                collapsed.append(TraceStep(
                    index: collapsed.count + 1,
                    command: "\(startCmd) (completed)",
                    outcome: filtered[index + 1].step.outcome
                ))
                index += 2
                continue
            }
        }
        collapsed.append(TraceStep(
            index: collapsed.count + 1,
            command: filtered[index].step.command,
            outcome: filtered[index].step.outcome
        ))
        index += 1
    }

    return collapsed
}
