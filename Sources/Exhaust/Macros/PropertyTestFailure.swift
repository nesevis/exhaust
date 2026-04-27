import CustomDump
import ExhaustCore
import Foundation

struct PropertyTestFailure<Output> {
    let counterexample: Output
    let original: Output?
    let sourceCode: String?
    let seed: UInt64?
    let iteration: Int
    let phaseBudget: UInt64
    /// The ``ChoiceSequence`` short-string representation.
    let blueprint: String?
    let propertyInvocations: Int?
    var replayHint: String?
    /// When `true`, renders only the replay seed — the `#expect` assertions provide per-value detail.
    var transparent: Bool = false

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

        if let seed {
            let encodedSeed = CrockfordBase32.encode(seed)
            lines.append("Property failed (iteration \(iteration)/\(phaseBudget), seed \(encodedSeed))")
        } else {
            lines.append("Property failed (iteration \(iteration)/\(phaseBudget))")
        }

        lines.append("")
        lines.append("Counterexample:")
        var counterexampleDump = ""
        customDump(counterexample, to: &counterexampleDump)
        for line in counterexampleDump.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append("  \(line)")
        }

        if let original {
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

        if let seed {
            lines.append("")
            lines.append("Reproduce: .replay(\"\(CrockfordBase32.encode(seed))\")")
        } else if let replayHint {
            lines.append("")
            lines.append(replayHint)
        }

        return lines.joined(separator: "\n")
    }

    /// Renders only the replay seed — the `#expect` assertions provide per-value detail.
    private func renderKeyValueTransparent() -> String {
        if let seed {
            "Reproduce: .replay(\"\(CrockfordBase32.encode(seed))\")"
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

        let encodedSeed = seed.map { CrockfordBase32.encode($0) }

        let logLine = JSONLLogLine(
            event: "property_failed",
            seed: encodedSeed,
            iteration: iteration,
            phaseBudget: phaseBudget,
            counterexample: transparent ? nil : counterexampleDump,
            original: originalDump,
            propertyInvocations: propertyInvocations,
            replay: encodedSeed.map { ".replay(\"\($0)\")" },
            replayHint: encodedSeed == nil ? replayHint : nil
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
