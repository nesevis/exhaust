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
    /// When `true`, reduction was attempted but produced no improvement over the original counterexample.
    var reductionProducedNoImprovement: Bool = false
    /// When `true`, the reduction was cut short by the wall-clock deadline and the counterexample may not be fully reduced.
    var reductionWasCapped: Bool = false
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
        customDump(counterexample, to: &counterexampleDump)
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

        if reductionProducedNoImprovement {
            lines.append("")
            lines.append("Note: this result could not be reduced.")
        } else if reductionWasCapped {
            lines.append("")
            lines.append("Note: Reduction halted by time limit. Increase .budget(...) to allow more reduction time.")
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
        customDump(counterexample, to: &counterexampleDump)

        var originalDump: String?
        if transparent == false, let original {
            var dump = ""
            customDump(original, to: &dump)
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
