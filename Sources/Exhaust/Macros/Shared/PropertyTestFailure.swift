import CustomDump
import ExhaustCore
import Foundation

/// Formats a property test failure for reporting in key-value or JSONL format.
struct PropertyTestFailure<Output> {
    let counterexample: Output
    let original: Output?
    let seed: UInt64?
    let iteration: Int
    let phaseBudget: UInt64
    /// The ``ChoiceSequence`` short-string representation.
    let blueprint: String?
    let propertyInvocations: Int?
    var reducedSequence: ChoiceSequence?
    var replayHint: String?
    /// When `true`, renders only the replay seed — the `#expect` assertions provide per-value detail.
    var transparent: Bool = false
    /// What the failure says about how reduction went, or `nil` when it has nothing to report. See ``ReductionNote`` for the precedence between the states.
    var reductionNote: ReductionNote?
    /// When `true`, includes a structural diff between the original and reduced values. Off by default because the diff is expensive for large values.
    var includeDiff: Bool = false

    /// Produces the encoded replay string including the iteration for direct reproduction.
    var encodedReplaySeed: String? {
        guard let seed else { return nil }
        return ReplaySeed.Resolved.sampling(seed: seed, iteration: iteration).encoded
    }

    /// Dispatches to the appropriate renderer based on the configured log format.
    func render(format: LogFormat) -> String {
        switch format {
            case .keyValue:
                renderKeyValue()
            case .jsonl:
                renderJSONL()
        }
    }

    // MARK: - Key-value format

    private func renderKeyValue() -> String {
        if transparent {
            return renderKeyValueTransparent()
        }

        var lines: [String] = []

        if let replaySeed = encodedReplaySeed {
            lines.append("Property failed (iteration \(iteration)/\(phaseBudget), seed \(replaySeed))")
        } else {
            lines.append("Property failed (iteration \(iteration)/\(phaseBudget))")
        }

        if let original {
            if let summary = summarizeReduction(original: original, reduced: counterexample, reducedSequence: reducedSequence) {
                lines.append("")
                lines.append("Reduction summary:")
                for line in summary.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("  \(line)")
                }
            }
        }

        lines.append("")
        lines.append("Counterexample:")
        var counterexampleDump = ""
        customDump(counterexample, to: &counterexampleDump, maxDepth: 3)
        for line in counterexampleDump.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append("  \(line)")
        }

        if includeDiff, let original {
            if let reductionDiff = diff(original, counterexample) {
                lines.append("")
                lines.append("Reduction diff:")
                for line in reductionDiff.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("  \(line)")
                }
            }
        }

        if let propertyInvocations {
            lines.append("")
            lines.append("Property invoked: \(propertyInvocations) times")
        }

        if let reductionNote {
            lines.append("")
            lines.append(reductionNote.message)
        }

        if let replaySeed = encodedReplaySeed {
            lines.append("")
            lines.append("Reproduce: .replay(\"\(replaySeed)\")")
        } else if let replayHint {
            lines.append("")
            lines.append(replayHint)
        }

        return lines.joined(separator: "\n")
    }

    /// Renders only the replay seed — the `#expect` assertions provide per-value detail.
    private func renderKeyValueTransparent() -> String {
        if let replaySeed = encodedReplaySeed {
            "Reproduce: .replay(\"\(replaySeed)\")"
        } else if let replayHint {
            replayHint
        } else {
            "Property failed (no replay seed available)"
        }
    }

    // MARK: - JSONL format

    private func renderJSONL() -> String {
        var counterexampleDump = ""
        customDump(counterexample, to: &counterexampleDump, maxDepth: 3)

        var originalDump: String?
        if transparent == false, let original {
            var dump = ""
            customDump(original, to: &dump, maxDepth: 3)
            originalDump = dump
        }

        let logLine = JSONLLogLine(
            event: "property_failed",
            seed: seed.map { ReplaySeed.encodeRawSeed($0) },
            iteration: iteration,
            phaseBudget: phaseBudget,
            counterexample: transparent ? nil : counterexampleDump,
            original: originalDump,
            propertyInvocations: propertyInvocations,
            replay: encodedReplaySeed.map { ".replay(\"\($0)\")" },
            replayHint: encodedReplaySeed == nil ? replayHint : nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(logLine),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{\"event\":\"property_failed\"}"
        }
        return json
    }
}

// MARK: - Reduction Note

/// What a failure reports about the reduction phase.
///
/// The states are mutually exclusive, and their precedence is the order the cases are tested in ``init(probes:invocations:stalledLeafCount:anyAcceptanceOccurred:producedNoImprovement:wasCapped:)``: a run that never materialized a candidate reports that ahead of the time limit, because raising the budget cannot help it, and the time limit outranks a stall because a truncated search says nothing about the shape of the landscape.
///
/// The counts arrive as arguments rather than being read from an ``ExhaustReport``. A report is filled in progressively across a run, and its invocation counts land only when the ledger is applied at the very end, so a caller reading them mid-run silently sees zero. Requiring them here puts the burden on the call site to supply a number it actually has.
enum ReductionNote {
    /// Probes were opened and none of them materialized, so the property never ran during reduction.
    case noCandidateMaterialized
    /// The wall-clock deadline ended reduction early.
    case timeLimit
    /// Reduction never accepted an improvement while leaves sit converged short of their reduction targets, which usually means the values are linked by a relationship no single-value move preserves.
    case stalled
    /// Reduction ran without improving the counterexample.
    case noImprovement

    /// - Parameters:
    ///   - probes: Reduction proposals opened by encoder passes and relax rounds.
    ///   - invocations: Property invocations attributed to the reduction phase.
    ///   - stalledLeafCount: Leaves that ended reduction converged short of their reduction target.
    ///   - anyAcceptanceOccurred: Whether any pass in the run accepted a probe.
    ///   - producedNoImprovement: Whether reduction returned the counterexample unchanged.
    ///   - wasCapped: Whether the wall-clock deadline ended reduction early.
    init?(
        probes: Int,
        invocations: Int,
        stalledLeafCount: Int,
        anyAcceptanceOccurred: Bool,
        producedNoImprovement: Bool,
        wasCapped: Bool
    ) {
        if probes > 0, invocations == 0 {
            self = .noCandidateMaterialized
        } else if wasCapped {
            self = .timeLimit
        } else if stalledLeafCount > 0, anyAcceptanceOccurred == false {
            self = .stalled
        } else if producedNoImprovement {
            self = .noImprovement
        } else {
            return nil
        }
    }

    var message: String {
        switch self {
            case .noCandidateMaterialized:
                "Note: reduction failed; no candidate materialized, so the property never ran during reduction. Check the generator for a filter or a bind the reduced choices cannot satisfy."
            case .timeLimit:
                "Note: Reduction halted by time limit. Increase .budget(...) to allow more reduction time."
            case .stalled:
                "Note: reduction stalled; the counterexample may not be minimal."
            case .noImprovement:
                "Note: this result could not be reduced."
        }
    }
}

// MARK: - JSONL log line

private struct JSONLLogLine: Encodable {
    let event: String
    let seed: String?
    let iteration: Int
    let phaseBudget: UInt64
    let counterexample: String?
    let original: String?
    let propertyInvocations: Int?
    let replay: String?
    let replayHint: String?
}
