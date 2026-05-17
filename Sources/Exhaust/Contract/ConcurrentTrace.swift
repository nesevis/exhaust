// Converts raw colon-delimited trace markers from the cooperative drain loop into presentable TraceSteps. Three post-processing passes: parse markers into steps with lane metadata, collapse no-op suspend/resume pairs, and merge adjacent started+completed pairs.

/// Converts raw trace markers into presentable TraceSteps with phase annotations.
///
/// Performs three post-processing passes: (1) parses colon-delimited markers into steps with structured lane metadata, (2) removes suspended/resumed pairs where no interleaving actually occurred between them, and (3) collapses adjacent started+completed pairs into a single entry.
func parseTrace(_ raw: [String]) -> [TraceStep] {
    var steps: [(step: TraceStep, lane: String)] = []
    var openCommand: [String: String] = [:]
    var stepNumber = 0

    for entry in raw {
        let parts = entry.split(separator: ":", maxSplits: 3).map(String.init)
        guard parts.count >= 2 else { continue }
        let kind = parts[0]
        let lane = parts[1]
        let label = parts.count >= 3 ? parts[2] : parts[1]

        switch kind {
        case "STARTED":
            if lane != "prefix" {
                openCommand[lane] = label
            }
            stepNumber += 1
            let phase = lane == "prefix" ? "(prefix)" : "(started)"
            steps.append((TraceStep(index: stepNumber, command: "\(label) \(phase)", outcome: .ok), lane))
        case "COMPLETED":
            openCommand[lane] = nil
            if lane == "prefix" {
                if let lastIndex = steps.lastIndex(where: { $0.step.command == "\(label) (prefix)" }) {
                    steps.remove(at: lastIndex)
                    stepNumber -= 1
                }
                stepNumber += 1
                steps.append((TraceStep(index: stepNumber, command: "\(label) (prefix)", outcome: .ok), lane))
            } else {
                stepNumber += 1
                steps.append((TraceStep(index: stepNumber, command: "\(label) (completed)", outcome: .ok), lane))
            }
        case "FAILED":
            openCommand[lane] = nil
            let message = parts.count >= 4 ? parts[3] : "failed"
            stepNumber += 1
            let phase = lane == "prefix" ? "(prefix)" : "(completed)"
            steps.append((TraceStep(index: stepNumber, command: "\(label) \(phase)", outcome: .invariantFailed(name: message)), lane))
        case "SUSPENDED":
            if let current = openCommand[lane] {
                stepNumber += 1
                steps.append((TraceStep(index: stepNumber, command: "\(current) (suspended)", outcome: .ok), lane))
            }
        case "RESUMED":
            if let current = openCommand[lane] {
                stepNumber += 1
                steps.append((TraceStep(index: stepNumber, command: "\(current) (resumed)", outcome: .ok), lane))
            }
        default:
            break
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
