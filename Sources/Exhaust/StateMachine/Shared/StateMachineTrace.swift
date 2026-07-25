import ExhaustCore
import Foundation

extension __ExhaustRuntime {
    /// Converts structured trace events into presentable TraceSteps with phase annotations.
    ///
    /// Performs two post-processing passes: (1) removes suspended/resumed pairs where no interleaving actually occurred between them, and (2) collapses adjacent started+completed pairs into a single entry. Both passes match on the typed ``TracePhase`` and command label; the parenthesised suffix is composed once at emit time, so rendered output is unchanged.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    static func buildTrace(_ events: [TraceEvent]) -> [TraceStep] {
        var entries: [TraceEntry] = []
        var openCommand: [TraceEvent.Lane: String] = [:]

        for event in events {
            let isPrefix = event.lane == .prefix
            switch event.kind {
                case .started:
                    if isPrefix == false {
                        openCommand[event.lane] = event.label
                    }
                    let phase: TracePhase = isPrefix ? .prefix : .started
                    entries.append(TraceEntry(phase: phase, label: event.label, lane: event.lane, outcome: .ok))
                case .completed:
                    openCommand[event.lane] = nil
                    if isPrefix {
                        if let lastIndex = entries.lastIndex(where: { $0.label == event.label && $0.phase == .prefix }) {
                            entries.remove(at: lastIndex)
                        }
                        entries.append(TraceEntry(phase: .prefix, label: event.label, lane: event.lane, outcome: .ok))
                    } else {
                        entries.append(TraceEntry(phase: .completed, label: event.label, lane: event.lane, outcome: .ok))
                    }
                case .skipped:
                    openCommand[event.lane] = nil
                    if isPrefix {
                        if let lastIndex = entries.lastIndex(where: { $0.label == event.label && $0.phase == .prefix }) {
                            entries.remove(at: lastIndex)
                        }
                        entries.append(TraceEntry(phase: .prefix, label: event.label, lane: event.lane, outcome: .skipped))
                    } else {
                        entries.append(TraceEntry(phase: .completed, label: event.label, lane: event.lane, outcome: .skipped))
                    }
                case let .failed(message, source):
                    openCommand[event.lane] = nil
                    let outcome: TraceStep.Outcome = switch source {
                        case .check: .checkFailed(message: message)
                        case .invariant: .invariantFailed(name: message)
                        case .error: .checkFailed(message: message)
                    }
                    if isPrefix {
                        if let lastIndex = entries.lastIndex(where: { $0.label == event.label && $0.phase == .prefix }) {
                            entries.remove(at: lastIndex)
                        }
                        entries.append(TraceEntry(phase: .prefix, label: event.label, lane: event.lane, outcome: outcome))
                    } else {
                        entries.append(TraceEntry(phase: .completed, label: event.label, lane: event.lane, outcome: outcome))
                    }
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

    /// Maps a command-run error to a trace outcome. ``TraceStep/Outcome/skipped`` means the command was skipped via ``StateMachineSkip`` and the caller should continue to the next command without checking invariants.
    private static func commandRunOutcome(for error: any Error) -> TraceStep.Outcome {
        switch error {
            case is StateMachineSkip:
                .skipped
            case let failure as StateMachineCheckFailure:
                .checkFailed(message: failure.message)
            default:
                .checkFailed(message: "\(error)")
        }
    }

    /// Maps an invariant-check error to a trace outcome.
    private static func invariantCheckOutcome(for error: any Error) -> TraceStep.Outcome {
        switch error {
            case let failure as StateMachineCheckFailure:
                .invariantFailed(name: failure.message ?? "unknown")
            default:
                .invariantFailed(name: "\(error)")
        }
    }

    /// Builds a sequential execution trace from a command sequence, recording per-command outcomes with invariant failure names. Shared by the sequential spec runner and the preemptive runner's smoke test.
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
            } catch {
                let outcome = commandRunOutcome(for: error)
                trace.append(TraceStep(index: step, command: description, outcome: outcome))
                if case .skipped = outcome { continue }
                return (trace, true)
            }

            do {
                try checkInvariants()
            } catch {
                trace.append(TraceStep(index: step, command: description, outcome: invariantCheckOutcome(for: error)))
                return (trace, true)
            }

            trace.append(TraceStep(index: step, command: description, outcome: .ok))
        }

        return (trace, false)
    }

    /// Renders a setup step for trace display, suffixed so the reader does not conclude it was a generated sequence member.
    ///
    /// The parameter is `some Any` rather than `CustomStringConvertible` because `SetupStep` defaults to `Never` for zero-setup specs, and `Never` does not conform. Synthesized setup enums are always `CustomStringConvertible`, so interpolation renders the real description at every reachable call site.
    static func setupTraceDescription(_ step: some Any) -> String {
        "\(step) (setup)"
    }

    /// Constructs a fresh spec and applies its setup step, recording the step as a trace entry.
    ///
    /// The trace-recording sibling of the ``StateMachineSpec/makeSpec(setupStep:)`` funnel: it exists so a throwing setup is attributed to the setup row rather than to the first command. A setup step's outcome can only be `.ok` or `.checkFailed`; no invariant check runs after setup. `steps` is empty for a spec without a `@Setup` method, which leaves the command trace unshifted.
    static func makeSpecRecordingSetupTrace<Spec: StateMachineSpec>(
        _: Spec.Type,
        setupStep: Spec.SetupStep?
    ) -> (spec: Spec, steps: [TraceStep], failed: Bool) {
        let spec = Spec()
        guard let setupStep else {
            return (spec, [], false)
        }
        let label = setupTraceDescription(setupStep)
        do {
            try spec.runSetup(setupStep)
            return (spec, [TraceStep(index: 1, command: label, outcome: .ok)], false)
        } catch {
            return (spec, [TraceStep(index: 1, command: label, outcome: .checkFailed(message: "\(error)"))], true)
        }
    }

    /// Applies a setup step to an already-constructed async spec while recording it as a trace entry. The async twin of ``makeSpecRecordingSetupTrace(_:setupStep:)``, split from construction because async callers construct inside their own bridged tasks.
    static func applySetupRecordingTrace<Spec: AsyncStateMachineSpec>(
        _ spec: Spec,
        setupStep: Spec.SetupStep?
    ) async -> (steps: [TraceStep], failed: Bool) {
        guard let setupStep else {
            return ([], false)
        }
        let label = setupTraceDescription(setupStep)
        do {
            try await spec.runSetup(setupStep)
            return ([TraceStep(index: 1, command: label, outcome: .ok)], false)
        } catch {
            return ([TraceStep(index: 1, command: label, outcome: .checkFailed(message: "\(error)"))], true)
        }
    }

    /// Prepends setup trace entries to command trace entries, renumbering the command steps so the trace counts through the setup rows first.
    static func joinTrace(setup: [TraceStep], commands: [TraceStep]) -> [TraceStep] {
        guard setup.isEmpty == false else {
            return commands
        }
        let offset = setup.count
        return setup + commands.map { TraceStep(index: $0.index + offset, command: $0.command, outcome: $0.outcome) }
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
            } catch {
                let outcome = commandRunOutcome(for: error)
                trace.append(TraceStep(index: step, command: description, outcome: outcome))
                if case .skipped = outcome { continue }
                return (trace, true)
            }

            do {
                try await checkInvariants()
            } catch {
                trace.append(TraceStep(index: step, command: description, outcome: invariantCheckOutcome(for: error)))
                return (trace, true)
            }

            trace.append(TraceStep(index: step, command: description, outcome: .ok))
        }

        return (trace, false)
    }
}

// MARK: - Inner types

/// A raw event emitted by the cooperative drain loop during command execution. These are intermediate records that ``buildTrace(_:)`` post-processes into presentable ``TraceStep`` values, collapsing no-op suspend/resume pairs and merging adjacent started+completed events for the same command.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
struct TraceEvent: Sendable {
    enum Kind: Sendable {
        case started
        case completed
        case skipped
        case failed(message: String, source: FailureSource)
        case suspended
        case resumed
    }

    enum FailureSource: Sendable {
        case check
        case invariant
        case error
    }

    enum Lane: Hashable, Sendable, CustomStringConvertible {
        case prefix
        case lane(LaneID)

        var description: String {
            switch self {
                case .prefix: "prefix"
                case let .lane(identifier): identifier.label.uppercased()
            }
        }
    }

    var kind: Kind
    var lane: Lane
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
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private struct TraceEntry {
    var phase: TracePhase
    var label: String
    var lane: TraceEvent.Lane
    var outcome: TraceStep.Outcome
}
