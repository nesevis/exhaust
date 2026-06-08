import Foundation

extension __ExhaustRuntime {
    /// Converts structured trace events into presentable TraceSteps with phase annotations.
    ///
    /// Performs two post-processing passes: (1) removes suspended/resumed pairs where no interleaving actually occurred between them, and (2) collapses adjacent started+completed pairs into a single entry. Both passes match on the typed ``TracePhase`` and command label; the parenthesised suffix is composed once at emit time, so rendered output is unchanged.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    static func buildTrace(_ events: [TraceEvent]) -> [TraceStep] {
        var entries: [TraceEntry] = []
        var openCommand: [String: String] = [:]

        for event in events {
            switch event.kind {
                case .started:
                    if event.lane != "prefix" {
                        openCommand[event.lane] = event.label
                    }
                    let phase: TracePhase = event.lane == "prefix" ? .prefix : .started
                    entries.append(TraceEntry(phase: phase, label: event.label, lane: event.lane, outcome: .ok))
                case .completed:
                    openCommand[event.lane] = nil
                    if event.lane == "prefix" {
                        if let lastIndex = entries.lastIndex(where: { $0.label == event.label && $0.phase == .prefix }) {
                            entries.remove(at: lastIndex)
                        }
                        entries.append(TraceEntry(phase: .prefix, label: event.label, lane: event.lane, outcome: .ok))
                    } else {
                        entries.append(TraceEntry(phase: .completed, label: event.label, lane: event.lane, outcome: .ok))
                    }
                case let .failed(message):
                    openCommand[event.lane] = nil
                    let phase: TracePhase = event.lane == "prefix" ? .prefix : .completed
                    entries.append(TraceEntry(phase: phase, label: event.label, lane: event.lane, outcome: .invariantFailed(name: message)))
                case .suspended:
                    if let current = openCommand[event.lane] {
                        entries.append(TraceEntry(phase: .suspended, label: current, lane: event.lane, outcome: .ok))
                    }
                case .resumed:
                    if let current = openCommand[event.lane] {
                        entries.append(TraceEntry(phase: .resumed, label: current, lane: event.lane, outcome: .ok))
                    }
            }
        }

        // Remove suspended/resumed pairs where no other lane ran between them.
        var filtered: [TraceEntry] = []
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            if entry.phase == .suspended {
                var hasInterleaving = false
                var resumeIndex: Int?
                for ahead in (index + 1) ..< entries.count {
                    let aheadEntry = entries[ahead]
                    if aheadEntry.label == entry.label,
                       aheadEntry.phase == .resumed || aheadEntry.phase == .completed
                    {
                        resumeIndex = ahead
                        break
                    }
                    if aheadEntry.lane != entry.lane {
                        hasInterleaving = true
                    }
                }

                if hasInterleaving {
                    filtered.append(entry)
                } else if let resumeIndex, entries[resumeIndex].phase == .resumed {
                    index = resumeIndex + 1
                    continue
                } else {
                    filtered.append(entry)
                }
            } else {
                filtered.append(entry)
            }
            index += 1
        }

        // Collapse: started immediately followed by completed for the same command.
        var collapsed: [TraceStep] = []
        index = 0
        while index < filtered.count {
            if index + 1 < filtered.count,
               filtered[index].phase == .started,
               filtered[index + 1].phase == .completed,
               filtered[index].label == filtered[index + 1].label
            {
                collapsed.append(TraceStep(
                    index: collapsed.count + 1,
                    command: "\(filtered[index].label) \(TracePhase.completed.suffix)",
                    outcome: filtered[index + 1].outcome
                ))
                index += 2
                continue
            }
            let entry = filtered[index]
            collapsed.append(TraceStep(
                index: collapsed.count + 1,
                command: "\(entry.label) \(entry.phase.suffix)",
                outcome: entry.outcome
            ))
            index += 1
        }

        return collapsed
    }

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

// MARK: - Inner types

// Converts structured trace events from the cooperative drain loop into presentable TraceSteps. Two post-processing passes: collapse no-op suspend/resume pairs, and merge adjacent started+completed pairs.

/// A raw event emitted by the cooperative drain loop during command execution. These are intermediate records that ``buildTrace(_:)`` post-processes into presentable ``TraceStep`` values — collapsing no-op suspend/resume pairs and merging adjacent started+completed events for the same command.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
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

/// The execution phase of a trace entry. Rendered as a parenthesised suffix on the command at emit time.
///
/// Carried as data through ``buildTrace(_:)``'s post-processing so the passes match on `phase` rather than parsing the display string. `prefix` is distinct from `started`/`completed` because a prefix command renders as a single `(prefix)` entry rather than a started/completed pair.
private enum TracePhase {
    case prefix
    case started
    case completed
    case suspended
    case resumed

    var suffix: String {
        switch self {
            case .prefix: "(prefix)"
            case .started: "(started)"
            case .completed: "(completed)"
            case .suspended: "(suspended)"
            case .resumed: "(resumed)"
        }
    }
}

/// One presentable trace entry before final indexing: phase, command label, owning lane, and outcome kept as typed fields.
private struct TraceEntry {
    var phase: TracePhase
    var label: String
    var lane: String
    var outcome: TraceStep.Outcome
}
